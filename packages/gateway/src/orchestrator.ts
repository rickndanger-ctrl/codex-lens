import {
  err,
  ok,
  type ApprovalContract,
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
 * A Failed Result means the change was not made and nothing was left behind. A
 * successful Result means the run completed and reported on itself: read
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
  if (!report.ok) {
    // The caller gets no handle on this path, so the sandbox is this
    // function's to clean up. Rolled back before disposal so a failure that
    // leaves the copy alive — a disposal error — still leaves it at baseline.
    await rollback(sandbox);
    await disposeSandbox(sandbox);
  }

  return report;
}
