import {
  err,
  ok,
  type ApprovalContract,
  type DomainError,
  type ExecutionPlan,
  type Result,
} from '@codex-lens/shared';

import { assertExecutionApproved } from './approval-binding.js';
import { applyEdit } from './codex/apply-edit.js';
import { createThread, initialize, type CodexClientOptions } from './codex/client.js';
import type { AppServerHandle } from './codex/transport.js';
import {
  generateExecutionPlan,
  type ExecutionPlanRequest,
} from './plan-generation.js';
import {
  captureDiff,
  disposeSandbox,
  prepareSandbox,
  rollback,
  type SandboxHandle,
} from './sandbox.js';
import { runTests, type TestRun } from './test-runner.js';

/**
 * Issues the approval for the execution plan this run generated.
 *
 * An execution plan is minted here, with a fresh id and digest, so no approval
 * that predates the run can name it. An issuer is what lets a caller approve
 * the plan it is actually shown: it receives the generated plan and answers
 * with a contract bound to it, or `undefined` for "not approved". Whatever it
 * returns still faces the same binding check as a caller-supplied contract, so
 * an issuer is a way to be asked, not a way to self-authorize.
 */
export type ExecutionApprovalIssuer = (
  plan: ExecutionPlan,
) => ApprovalContract | undefined | Promise<ApprovalContract | undefined>;

export type ExecutionApproval = ApprovalContract | ExecutionApprovalIssuer;

export interface VerticalSliceOptions {
  /** The requested change, as the requester wrote it. */
  request: ExecutionPlanRequest;
  /** Registry id of the editable repo the change targets. */
  repoId: string;
  /**
   * The approval authorizing this execution, or an issuer that grants one for
   * the generated plan. Omitted means unapproved, which stops the run.
   */
  approval?: ExecutionApproval;
  client: AppServerHandle;
  /** Per-request budget for the Codex handshake, thread start and edit turn. */
  codexOptions?: CodexClientOptions;
  /** Wall-clock budget for the verification run. */
  testTimeoutMs?: number;
}

export interface VerticalSliceReport {
  /**
   * `Complete` only when the edit landed and the plan's own command verified
   * it. `Failed` means the tests rejected the edit and it has been rolled back.
   */
  status: 'Complete' | 'Failed';
  /** The generated plan the approval was checked against. */
  plan: ExecutionPlan;
  /** `plan.contentDigest` — the exact content the approval authorized. */
  planDigest: string;
  /** Sandbox-relative paths Codex changed, in the order they were written. */
  appliedFiles: string[];
  /** Unified diff of the edit, captured before any rollback. */
  diff: string;
  finalTests: TestRun;
  /**
   * The working copy the edit was made in. The caller owns it and must dispose
   * it; a failure that produces a Failed Result disposes it instead, so a
   * caller only ever holds a sandbox it was actually handed.
   */
  sandbox: SandboxHandle;
  /** True when the tree was returned to its baseline because tests failed. */
  rolledBack: boolean;
}

/**
 * Code of the error `runVerticalSlice` fails with when a run failed *and* the
 * working copy it made could not be removed afterwards. Distinct from the
 * failure that triggered cleanup, because it means something different to the
 * caller: not "the change was not made" but "the change was not made and there
 * is a sandbox still on disk that only you can now get rid of".
 */
export const SANDBOX_CLEANUP_FAILED = 'SANDBOX_CLEANUP_FAILED';

/**
 * What `SANDBOX_CLEANUP_FAILED` carries in `error.details`: everything needed
 * to either retry the cleanup or report the leak.
 */
export interface SandboxCleanupFailure {
  /**
   * The undisposed working copy. Still live as far as `sandbox.ts` is
   * concerned, so it remains a valid argument to `disposeSandbox` and
   * `rollback` — this is the handle a caller retries with.
   */
  sandbox: SandboxHandle;
  /** The failure that ended the run and started cleanup in the first place. */
  cause: DomainError;
  /** Why disposal could not remove the copy. */
  disposeError: DomainError;
  /**
   * Why the copy could not be returned to its baseline, when that also failed.
   * Absent means the surviving copy is at its baseline: it holds no edit from
   * this run, only the pristine source.
   */
  rollbackError?: DomainError;
  /** False when `rollbackError` is set: the copy may still hold the edit. */
  atBaseline: boolean;
}

/**
 * Reads the recovery context off a `runVerticalSlice` failure, or `undefined`
 * if the error is not a cleanup failure. Callers use this rather than reaching
 * into `details` themselves, which is typed `unknown` by design.
 */
export function readSandboxCleanupFailure(
  error: DomainError,
): SandboxCleanupFailure | undefined {
  return error.code === SANDBOX_CLEANUP_FAILED
    ? (error.details as SandboxCleanupFailure)
    : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Reduces the two approval shapes to one contract, without judging it: every
 * answer here still goes through `assertExecutionApproved`.
 */
async function resolveApproval(
  approval: ExecutionApproval | undefined,
  plan: ExecutionPlan,
): Promise<Result<ApprovalContract>> {
  if (approval === undefined) {
    return err(
      'EXECUTION_APPROVAL_MISSING',
      'No approval was supplied for the execution plan',
    );
  }

  if (typeof approval === 'function') {
    let issued: ApprovalContract | undefined;
    try {
      issued = await approval(plan);
    } catch (error) {
      // A throwing issuer is an approval that could not be obtained, not an
      // approval that was granted. It stops the run like any other refusal.
      return err(
        'EXECUTION_APPROVAL_UNAVAILABLE',
        `The approval issuer failed: ${errorMessage(error)}`,
      );
    }
    if (issued === undefined) {
      return err(
        'EXECUTION_APPROVAL_MISSING',
        'The approval issuer did not approve the execution plan',
      );
    }
    return resolveApproval(issued, plan);
  }

  // `assertExecutionApproved` reads through `approval.target`, so a value that
  // is not contract-shaped would throw there rather than be refused. Checked
  // here so an unapproved run always ends in a Failed Result.
  if (!isRecord(approval) || !isRecord(approval.target)) {
    return err(
      'EXECUTION_APPROVAL_MISSING',
      'Approval is not an approval contract',
    );
  }

  return ok(approval);
}

/**
 * The steps that can leave changes behind. Split out so every exit from here
 * passes through one cleanup path in `runVerticalSlice`.
 */
async function editAndVerify(
  plan: ExecutionPlan,
  sandbox: SandboxHandle,
  options: VerticalSliceOptions,
): Promise<Result<VerticalSliceReport>> {
  const command = plan.expectedCommands[0];
  if (command === undefined) {
    return err(
      'PLAN_NO_TEST_COMMAND',
      'Execution plan names no command to verify the change with',
    );
  }

  const thread = await createThread(options.client, {
    ...options.codexOptions,
    cwd: sandbox.root,
  });
  if (!thread.ok) {
    return thread;
  }

  const applied = await applyEdit(
    options.client,
    thread.value.threadId,
    plan,
    sandbox,
    options.codexOptions,
  );
  if (!applied.ok) {
    return applied;
  }

  // Captured before the tests run, so the diff is reported whatever they say.
  const diff = await captureDiff(sandbox);
  if (!diff.ok) {
    return diff;
  }

  // The plan's own command, held to the plan's own allowlist: the command that
  // verifies an approved edit is the one the approval covers, not one chosen
  // after the fact.
  const tests = await runTests(
    {
      root: sandbox.root,
      allowedCommands: plan.expectedCommands,
      ...(options.testTimeoutMs === undefined
        ? {}
        : { timeoutMs: options.testTimeoutMs }),
    },
    command,
  );
  if (!tests.ok) {
    return tests;
  }

  const passed = tests.value.success;
  if (!passed) {
    const restored = await rollback(sandbox);
    if (!restored.ok) {
      return restored;
    }
  }

  return ok({
    status: passed ? 'Complete' : 'Failed',
    plan,
    planDigest: plan.contentDigest,
    appliedFiles: applied.value.changedFiles,
    diff: diff.value,
    finalTests: tests.value,
    sandbox,
    rolledBack: !passed,
  });
}

/**
 * Runs one approved request end to end: plan, approval check, sandbox, Codex
 * edit, verification.
 *
 * The order is the point. The plan is generated first because it is what the
 * approval must name; the approval is checked before anything is copied,
 * started or written, so an unapproved request costs nothing and changes
 * nothing. Auth is proven next, before the sandbox exists: Codex with no
 * credentials cannot make the edit, and finding that out after the copy would
 * leave a working copy behind for no reason.
 *
 * Every write happens inside a disposable sandbox — the requested repo itself
 * is never touched — and an edit the tests reject is rolled back to its
 * baseline rather than handed back half-applied.
 *
 * A Failed Result means the change was not made. It normally also means nothing
 * was left behind — with one exception it names rather than hides: if the
 * sandbox could not be removed, the failure is `SANDBOX_CLEANUP_FAILED` and
 * carries the surviving sandbox's handle. Read it with
 * `readSandboxCleanupFailure` and dispose the copy; nobody else holds it.
 *
 * A successful Result means the run completed and reported on itself: read
 * `status` to learn whether the edit survived verification, and dispose the
 * sandbox it returns.
 */
export async function runVerticalSlice(
  options: VerticalSliceOptions,
): Promise<Result<VerticalSliceReport>> {
  const planned = generateExecutionPlan(options.request, options.repoId);
  if (!planned.ok) {
    return planned;
  }
  const plan = planned.value;

  const contract = await resolveApproval(options.approval, plan);
  if (!contract.ok) {
    return contract;
  }
  const approved = assertExecutionApproved(plan, contract.value);
  if (!approved.ok) {
    return approved;
  }

  const session = await initialize(options.client, options.codexOptions);
  if (!session.ok) {
    return session;
  }

  const prepared = await prepareSandbox(options.repoId);
  if (!prepared.ok) {
    return prepared;
  }
  const sandbox = prepared.value;

  const report = await editAndVerify(plan, sandbox, options);
  if (report.ok) {
    return report;
  }

  return cleanUpAfterFailure(sandbox, report.error);
}

/**
 * Removes the working copy a failed run leaves behind, and answers for it.
 *
 * The caller gets no handle on this path, so the sandbox is this function's to
 * clean up: nobody else can. Rollback runs before disposal so that if the copy
 * does survive, it survives at its baseline rather than holding a half-applied
 * edit.
 *
 * Disposal is what decides the answer. If the copy is gone, the run's original
 * failure is the whole truth — nothing was left behind, and a rollback that
 * failed on a tree that no longer exists is moot, so it is not reported. If the
 * copy is still there, saying only "the edit failed" would be a promise this
 * function did not keep: there is a live sandbox, and this is the last moment
 * anyone holds the handle to it. So the failure is replaced by one that carries
 * that handle, with the original failure inside it, and the sandbox is left
 * registered so the handle still works.
 */
async function cleanUpAfterFailure(
  sandbox: SandboxHandle,
  cause: DomainError,
): Promise<Result<never>> {
  const restored = await rollback(sandbox);
  const disposed = await disposeSandbox(sandbox);

  if (disposed.ok) {
    return { ok: false, error: cause };
  }

  const details: SandboxCleanupFailure = {
    sandbox,
    cause,
    disposeError: disposed.error,
    ...(restored.ok ? {} : { rollbackError: restored.error }),
    atBaseline: restored.ok,
  };

  return err(
    SANDBOX_CLEANUP_FAILED,
    `The run failed (${cause.code}: ${cause.message}) and its sandbox at "${sandbox.root}" could not be removed (${disposed.error.code}: ${disposed.error.message}). ` +
      (restored.ok
        ? 'The copy is at its baseline and holds no edit from this run.'
        : `It also could not be rolled back (${restored.error.code}: ${restored.error.message}), so it may still hold the edit.`) +
      ' Dispose it with the handle in this error.',
    details,
  );
}
