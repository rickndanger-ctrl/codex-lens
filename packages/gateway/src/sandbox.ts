import { spawn } from 'node:child_process';
import { lstatSync, realpathSync } from 'node:fs';
import { cp, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { err, ok, type Result } from '@codex-lens/shared';

import { canonicalizePath, isWithinRoot } from './registry/pathSafety.js';
import { assertEditableTarget, resolveRepo } from './registry.js';

const GIT_TIMEOUT_MS = 60_000;

/** Never copied into a sandbox: the source VCS state and installed packages. */
const EXCLUDED_FROM_COPY = new Set(['.git', 'node_modules']);

const GIT_DIR = '.git';
const SANDBOX_PREFIX = 'codex-lens-sandbox-';
const SANDBOX_BRANCH = 'sandbox';
const BASELINE_MESSAGE = 'sandbox baseline';

export interface SandboxHandle {
  /**
   * Absolute path to the isolated working copy. Named `root` so a handle is
   * structurally usable as the `Sandbox` that `runTests` takes.
   */
  root: string;
  /** Registry id the sandbox was prepared from. */
  repoId: string;
  /**
   * The repo this copy came from, for reference only. Never trusted for
   * authorization — `writeFileInSandbox` re-resolves the source from `repoId`
   * so tampering with this field cannot widen what a write may touch.
   */
  sourceRoot: string;
  /** Commit holding the pristine copy; `rollback` returns the tree to it. */
  baselineCommit: string;
}

interface SandboxRecord {
  repoId: string;
  sourceRoot: string;
  baselineCommit: string;
}

/**
 * The sandboxes this module created, keyed by canonical root.
 *
 * A handle is a plain object, so a caller can hand back one with any `root` it
 * likes. That root is what every later operation acts on: it is the cwd of
 * `git reset --hard` and `git clean -fd`, and the argument to `rm -rf`. Nothing
 * about the string itself distinguishes a real sandbox from a source checkout
 * or a home directory, so a handle is not evidence — it is a lookup key, and
 * only a root this module minted and has not yet disposed is honoured.
 */
const LIVE_SANDBOXES = new Map<string, SandboxRecord>();

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * The baseline is the only caller-reachable value that reaches a git argv.
 * Requiring a bare object name keeps it from being read as an option, so no
 * git invocation here can be steered by the contents of a handle.
 */
const OBJECT_NAME = /^[0-9a-f]{7,64}$/u;

interface AuthenticSandbox {
  /** Canonical root, resolved from disk rather than taken from the handle. */
  root: string;
  record: SandboxRecord;
}

/**
 * Resolves a handle to a sandbox this module actually created, or refuses.
 *
 * Every operation that touches the filesystem or a git argv goes through here
 * first, so an unrecognized root is rejected before anything is read, reset,
 * cleaned, or removed.
 */
function authenticate(sandbox: SandboxHandle): Result<AuthenticSandbox> {
  if (typeof sandbox.root !== 'string' || sandbox.root.trim().length === 0) {
    return err(
      'INVALID_SANDBOX_ROOT',
      'Sandbox root must be a non-empty string',
    );
  }

  let root: string;
  try {
    root = canonicalizePath(sandbox.root);
  } catch {
    return err(
      'INVALID_SANDBOX_ROOT',
      `Sandbox root does not exist or cannot be resolved: "${sandbox.root}"`,
    );
  }

  const record = LIVE_SANDBOXES.get(root);
  if (record === undefined) {
    return err(
      'UNKNOWN_SANDBOX',
      `Not a live sandbox created by prepareSandbox: "${sandbox.root}"`,
    );
  }

  return ok({ root, record });
}

/**
 * The baseline a git command may name. Shape is checked first so a handle
 * carrying an option-shaped string is refused as such; the value is then held
 * to the one this module recorded, so a well-formed but foreign commit cannot
 * steer a reset either.
 */
function assertBaseline(
  sandbox: SandboxHandle,
  record: SandboxRecord,
): Result<string> {
  if (
    typeof sandbox.baselineCommit !== 'string' ||
    !OBJECT_NAME.test(sandbox.baselineCommit)
  ) {
    return err(
      'INVALID_SANDBOX_BASELINE',
      `Sandbox baseline is not a git object name: "${String(sandbox.baselineCommit)}"`,
    );
  }
  if (sandbox.baselineCommit !== record.baselineCommit) {
    return err(
      'SANDBOX_HANDLE_MISMATCH',
      `Sandbox baseline does not match the recorded baseline for this sandbox: "${sandbox.baselineCommit}"`,
    );
  }

  return ok(record.baselineCommit);
}

interface GitOutcome {
  code: number | null;
  stdout: string;
  stderr: string;
}

/**
 * Runs git with the caller's config neutralized, so a sandbox behaves the same
 * regardless of the developer's global git settings (identity, hooks, gpg,
 * default branch) and never blocks on a credential prompt. The exit code is
 * returned rather than judged: some callers here ask git a question whose
 * answer is a non-zero exit.
 */
function spawnGit(
  args: readonly string[],
  cwd: string,
): Promise<Result<GitOutcome>> {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (/^GIT_/u.test(key)) {
      delete env[key];
    }
  }

  env.GIT_CONFIG_GLOBAL = '/dev/null';
  env.GIT_CONFIG_SYSTEM = '/dev/null';
  env.GIT_TERMINAL_PROMPT = '0';
  env.GIT_OPTIONAL_LOCKS = '0';

  return new Promise((resolve) => {
    const child = spawn('git', [...args], {
      cwd,
      env,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const stdout: string[] = [];
    const stderr: string[] = [];
    let settled = false;

    const timer = setTimeout(() => {
      child.kill('SIGKILL');
    }, GIT_TIMEOUT_MS);
    timer.unref();

    const settle = (result: Result<GitOutcome>): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => stdout.push(chunk));
    child.stderr.on('data', (chunk: string) => stderr.push(chunk));

    child.on('error', (error) => {
      settle(err('GIT_COMMAND_FAILED', errorMessage(error)));
    });

    // `close` rather than `exit`: stdout must be drained before it is read.
    child.on('close', (code, signal) => {
      if (signal === 'SIGKILL') {
        settle(
          err(
            'GIT_COMMAND_TIMED_OUT',
            `git ${args[0] ?? ''} exceeded its ${GIT_TIMEOUT_MS}ms budget`,
          ),
        );
        return;
      }
      settle(ok({ code, stdout: stdout.join(''), stderr: stderr.join('') }));
    });
  });
}

/** Runs git and treats any non-zero exit as a failure. */
async function runGit(
  args: readonly string[],
  cwd: string,
): Promise<Result<string>> {
  const outcome = await spawnGit(args, cwd);
  if (!outcome.ok) {
    return outcome;
  }
  if (outcome.value.code !== 0) {
    return err(
      'GIT_COMMAND_FAILED',
      `git ${args.join(' ')} exited ${String(outcome.value.code)}: ${outcome.value.stderr.trim()}`,
    );
  }

  return ok(outcome.value.stdout);
}

/**
 * Runs a git command whose answer *is* its exit code (`check-ignore`,
 * `ls-files --error-unmatch`): 0 means yes, 1 means no, anything else is a real
 * failure and must not be read as a no.
 */
async function runGitPredicate(
  args: readonly string[],
  cwd: string,
): Promise<Result<boolean>> {
  const outcome = await spawnGit(args, cwd);
  if (!outcome.ok) {
    return outcome;
  }
  const { code, stderr } = outcome.value;
  if (code !== 0 && code !== 1) {
    return err(
      'GIT_COMMAND_FAILED',
      `git ${args.join(' ')} exited ${String(code)}: ${stderr.trim()}`,
    );
  }

  return ok(code === 0);
}

/**
 * Containment decided on the resolved strings alone. `isWithinRoot` canonicalizes
 * and so answers `false` for a path that does not exist yet, which a write
 * creating a new directory legitimately does; the symlink question it exists to
 * answer is asked separately, against the nearest path that is real.
 */
function isLexicallyWithin(candidate: string, root: string): boolean {
  const relative = path.relative(root, candidate);

  return (
    relative === '' ||
    (!relative.startsWith(`..${path.sep}`) &&
      relative !== '..' &&
      !path.isAbsolute(relative))
  );
}

/**
 * Deepest ancestor of `target` that exists on disk, `target` itself included.
 * A path that does not exist yet cannot be canonicalized, so containment and
 * editability are decided against the closest real directory above it.
 */
function nearestExistingPath(target: string): string | undefined {
  let current = path.resolve(target);
  for (;;) {
    try {
      realpathSync.native(current);
      return current;
    } catch {
      const parent = path.dirname(current);
      if (parent === current) {
        return undefined;
      }
      current = parent;
    }
  }
}

/**
 * Refuses a write git would not show as a change.
 *
 * An ignored path is invisible to `captureDiff` and survives the `clean` that
 * rollback runs, so a write to one would be a change no reviewer sees and no
 * rollback undoes. Ignored files that were already in the copy are exempt:
 * `prepareSandbox` force-adds them, so they are tracked, and a change to one
 * both shows up in the diff and is restored by `reset --hard`.
 */
async function assertTrackable(
  root: string,
  relative: string,
): Promise<Result<void>> {
  const ignored = await runGitPredicate(
    ['check-ignore', '-q', '--', relative],
    root,
  );
  if (!ignored.ok) {
    return ignored;
  }
  if (!ignored.value) {
    return ok(undefined);
  }

  const tracked = await runGitPredicate(
    ['ls-files', '--error-unmatch', '--', relative],
    root,
  );
  if (!tracked.ok) {
    return tracked;
  }
  if (tracked.value) {
    return ok(undefined);
  }

  return err(
    'SANDBOX_WRITE_NOT_TRACKABLE',
    `Write target is git-ignored, so the change would not appear in a diff or survive a rollback: "${relative}"`,
  );
}

export async function prepareSandbox(
  repoId: string,
): Promise<Result<SandboxHandle>> {
  const repo = resolveRepo(repoId);
  if (!repo.ok) {
    return repo;
  }

  // The source must itself be an editable target: preparing a sandbox of the
  // codex-lens repo is refused here rather than at write time.
  const editable = assertEditableTarget(repo.value.path);
  if (!editable.ok) {
    return editable;
  }
  const sourceRoot = editable.value;

  let root: string;
  try {
    // realpath first: on macOS os.tmpdir() is a symlink, and an uncanonical
    // root would fail every later containment check.
    root = await mkdtemp(
      path.join(realpathSync.native(os.tmpdir()), SANDBOX_PREFIX),
    );
    root = realpathSync.native(root);
  } catch (error) {
    return err('SANDBOX_CREATE_FAILED', errorMessage(error));
  }

  try {
    await cp(sourceRoot, root, {
      recursive: true,
      dereference: false,
      filter: (src) => !EXCLUDED_FROM_COPY.has(path.basename(src)),
    });
  } catch (error) {
    await rm(root, { recursive: true, force: true });
    return err('SANDBOX_COPY_FAILED', errorMessage(error));
  }

  const steps: readonly (readonly string[])[] = [
    ['init', '-b', SANDBOX_BRANCH],
    // `-f` so ignored files in the copy are part of the baseline too. Without
    // it they would sit outside git's view entirely: absent from every diff,
    // and untouched by both `reset --hard` and a `clean` that spares ignored
    // files. Tracking them is what lets rollback restore the copy as taken.
    ['add', '-A', '-f'],
    [
      '-c',
      'user.name=codex-lens',
      '-c',
      'user.email=codex-lens@invalid',
      'commit',
      '--no-gpg-sign',
      '--allow-empty',
      '-m',
      BASELINE_MESSAGE,
    ],
  ];
  for (const step of steps) {
    const result = await runGit(step, root);
    if (!result.ok) {
      await rm(root, { recursive: true, force: true });
      return result;
    }
  }

  const head = await runGit(['rev-parse', 'HEAD'], root);
  if (!head.ok) {
    await rm(root, { recursive: true, force: true });
    return head;
  }

  const record: SandboxRecord = {
    repoId: repo.value.id,
    sourceRoot,
    baselineCommit: head.value.trim(),
  };
  LIVE_SANDBOXES.set(root, record);

  return ok({ root, ...record });
}

/**
 * Writes `content` to `relPath` inside the sandbox.
 *
 * Three independent guards must all pass. The physical one keeps the write
 * inside the sandbox root — checked lexically, then again against the resolved
 * ancestor so a symlink cannot redirect it out. The policy one runs
 * `assertEditableTarget` on the path this write *stands for* in the real repo:
 * a sandbox lives under a tmp dir, which is not a registered repo, so asking
 * that question about the physical path would reject every write. Asking it
 * about the source path is what actually enforces the ticket-1 rule that only
 * an editable repo may be modified. The third keeps the write reviewable: a
 * change git cannot see is a change nobody can review or undo, so it is refused
 * rather than made invisibly.
 */
export async function writeFileInSandbox(
  sandbox: SandboxHandle,
  relPath: string,
  content: string,
): Promise<Result<string>> {
  if (typeof relPath !== 'string' || relPath.trim().length === 0) {
    return err(
      'INVALID_SANDBOX_PATH',
      'Sandbox-relative path must be a non-empty string',
    );
  }
  if (path.isAbsolute(relPath)) {
    return err(
      'SANDBOX_ESCAPE_REJECTED',
      `Sandbox-relative path must not be absolute: "${relPath}"`,
    );
  }
  const segments = relPath.split(/[\\/]+/u);
  if (segments.includes('..')) {
    return err(
      'SANDBOX_ESCAPE_REJECTED',
      `Sandbox-relative path must not contain "..": "${relPath}"`,
    );
  }
  // The sandbox's own git dir is the record of what changed; a write into it
  // would rewrite the very thing captureDiff and rollback read.
  if (segments[0] === GIT_DIR) {
    return err(
      'SANDBOX_WRITE_NOT_TRACKABLE',
      `Sandbox-relative path must not be inside the sandbox git directory: "${relPath}"`,
    );
  }

  const authentic = authenticate(sandbox);
  if (!authentic.ok) {
    return authentic;
  }
  const { root } = authentic.value;

  const target = path.resolve(root, relPath);
  if (target === root || !isLexicallyWithin(target, root)) {
    return err(
      'SANDBOX_ESCAPE_REJECTED',
      `Write target escapes the sandbox root: "${relPath}"`,
    );
  }

  // Re-resolve the source from the id: the handle's own sourceRoot is untrusted.
  // The id itself is taken as the caller gives it rather than from the record,
  // so this asks the editability question about the repo the caller claims the
  // write is for. A false claim cannot widen anything — the write has already
  // been confined to the sandbox root above, and `resolveRepo` only ever
  // answers with a registered repo — it can only get the write refused.
  const repo = resolveRepo(sandbox.repoId);
  if (!repo.ok) {
    return repo;
  }
  const logicalTarget = path.resolve(repo.value.path, relPath);
  const logicalExisting = nearestExistingPath(logicalTarget);
  if (logicalExisting === undefined) {
    return err(
      'INVALID_TARGET_PATH',
      `Target path cannot be resolved in repo "${sandbox.repoId}": "${relPath}"`,
    );
  }
  const editable = assertEditableTarget(logicalExisting);
  if (!editable.ok) {
    return editable;
  }

  // A symlink already at the target would write through to its destination.
  try {
    if (lstatSync(target).isSymbolicLink()) {
      return err(
        'SANDBOX_ESCAPE_REJECTED',
        `Write target is a symlink: "${relPath}"`,
      );
    }
  } catch {
    // Target does not exist yet; nothing to write through.
  }

  // Resolve the deepest real directory above the target before creating
  // anything, so mkdir cannot follow a symlink out of the sandbox.
  const physicalExisting = nearestExistingPath(target);
  if (physicalExisting === undefined || !isWithinRoot(physicalExisting, root)) {
    return err(
      'SANDBOX_ESCAPE_REJECTED',
      `Write target escapes the sandbox root: "${relPath}"`,
    );
  }

  const trackable = await assertTrackable(
    root,
    path.relative(root, target).split(path.sep).join('/'),
  );
  if (!trackable.ok) {
    return trackable;
  }

  try {
    await mkdir(path.dirname(target), { recursive: true });
  } catch (error) {
    return err('SANDBOX_WRITE_FAILED', errorMessage(error));
  }

  if (!isWithinRoot(path.dirname(target), root)) {
    return err(
      'SANDBOX_ESCAPE_REJECTED',
      `Write target escapes the sandbox root: "${relPath}"`,
    );
  }

  try {
    await writeFile(target, content, { encoding: 'utf8', flag: 'w' });
  } catch (error) {
    return err('SANDBOX_WRITE_FAILED', errorMessage(error));
  }

  return ok(target);
}

/**
 * Unified diff of every change made since `prepareSandbox`. Untracked files are
 * staged as intent-to-add first so new files appear in the diff; that only
 * touches the index, and `rollback` discards it either way.
 */
export async function captureDiff(
  sandbox: SandboxHandle,
): Promise<Result<string>> {
  const authentic = authenticate(sandbox);
  if (!authentic.ok) {
    return authentic;
  }
  const { root, record } = authentic.value;

  const baseline = assertBaseline(sandbox, record);
  if (!baseline.ok) {
    return baseline;
  }

  const intentToAdd = await runGit(['add', '-A', '-N'], root);
  if (!intentToAdd.ok) {
    return intentToAdd;
  }

  return runGit(['diff', baseline.value], root);
}

/**
 * Restores the sandbox to its baseline: tracked files are reset and untracked
 * files removed. `git clean` deliberately omits `-x`, so ignored artifacts such
 * as an installed node_modules survive a rollback. Nothing this module writes
 * can hide there: `writeFileInSandbox` refuses an ignored target that the
 * baseline does not already track.
 */
export async function rollback(sandbox: SandboxHandle): Promise<Result<void>> {
  const authentic = authenticate(sandbox);
  if (!authentic.ok) {
    return authentic;
  }
  const { root, record } = authentic.value;

  const baseline = assertBaseline(sandbox, record);
  if (!baseline.ok) {
    return baseline;
  }

  const reset = await runGit(['reset', '--hard', baseline.value], root);
  if (!reset.ok) {
    return reset;
  }

  const clean = await runGit(['clean', '-fd'], root);
  if (!clean.ok) {
    return clean;
  }

  return ok(undefined);
}

/**
 * Removes the working copy. A sandbox is disposable; this is not a rollback.
 * This is the recursive delete, so the handle is authenticated first: only a
 * root this module minted is ever passed to `rm`.
 */
export async function disposeSandbox(
  sandbox: SandboxHandle,
): Promise<Result<void>> {
  const authentic = authenticate(sandbox);
  if (!authentic.ok) {
    return authentic;
  }
  const { root } = authentic.value;

  try {
    await rm(root, { recursive: true, force: true });
  } catch (error) {
    return err('SANDBOX_DISPOSE_FAILED', errorMessage(error));
  }
  LIVE_SANDBOXES.delete(root);

  return ok(undefined);
}
