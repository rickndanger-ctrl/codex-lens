import { readFile } from 'node:fs/promises';
import path from 'node:path';

import {
  ApprovalStatus,
  ApprovalTargetType,
  createApprovalContract,
  type ApprovalContract,
  type ExecutionPlan,
} from '@codex-lens/shared';
import { afterEach, describe, expect, it } from 'vitest';

import type {
  AppServerHandle,
  AppServerMessage,
} from '../src/codex/transport.js';
import {
  runVerticalSlice,
  type VerticalSliceReport,
} from '../src/orchestrator.js';
import type { ExecutionPlanRequest } from '../src/plan-generation.js';
import { SAMPLE_REPO_ID, SAMPLE_REPO_ROOT } from '../src/registryConfig.js';
import { disposeSandbox, type SandboxHandle } from '../src/sandbox.js';

const TIMEOUT_MS = 60_000;
const THREAD_ID = '019f63c2-8b22-7613-89ce-023b27e0be10';
const TURN_ID = '019f63c2-8b22-7613-89ce-023b27e0be11';

const CALCULATOR = 'src/calculator.js';
const FIXED_CALCULATOR = `export function add(left, right) {
  return left + right;
}

export function multiply(left, right) {
  return left * right;
}
`;
/** Still wrong, and wrong in a way the fixture's own tests catch. */
const BROKEN_CALCULATOR = FIXED_CALCULATOR.replace(
  'left + right',
  'left * right',
);

const live = new Set<SandboxHandle>();

interface FakeClient extends AppServerHandle {
  sent: AppServerMessage[];
  /** Methods sent, in order — the run's whole footprint on Codex. */
  methods: string[];
}

interface FakeClientOptions {
  /** Edits the scripted turn returns as its final agent message. */
  edits?: readonly { path: string; content: string }[];
  /** `null` models a Codex home nobody has logged into. */
  authMethod?: string | null;
}

function createFakeClient(options: FakeClientOptions = {}): FakeClient {
  const { edits = [], authMethod = 'chatgpt' } = options;
  const listeners = new Set<(message: AppServerMessage) => void>();
  const sent: AppServerMessage[] = [];
  const methods: string[] = [];
  const emit = (message: AppServerMessage): void => {
    for (const listener of [...listeners]) listener(message);
  };

  const item = {
    type: 'agentMessage',
    id: 'agent-final',
    text: JSON.stringify({ edits }),
  };

  return {
    sent,
    methods,
    async send(message) {
      sent.push(message);
      if (typeof message.method === 'string') methods.push(message.method);

      const respond = (result: Record<string, unknown>): void => {
        queueMicrotask(() => {
          emit({ jsonrpc: '2.0', id: message.id, result });
        });
      };

      switch (message.method) {
        case 'initialize':
          respond({ userAgent: 'fake-codex/0.0.0' });
          return;
        case 'getAuthStatus':
          respond(
            authMethod === null
              ? { authMethod: null, requiresOpenaiAuth: true }
              : { authMethod },
          );
          return;
        case 'thread/start':
          respond({ thread: { id: THREAD_ID } });
          return;
        case 'turn/start':
          queueMicrotask(() => {
            emit({
              jsonrpc: '2.0',
              id: message.id,
              result: {
                turn: { id: TURN_ID, items: [], status: 'inProgress', error: null },
              },
            });
            emit({
              jsonrpc: '2.0',
              method: 'item/completed',
              params: { threadId: THREAD_ID, turnId: TURN_ID, item },
            });
            emit({
              jsonrpc: '2.0',
              method: 'turn/completed',
              params: {
                threadId: THREAD_ID,
                turn: {
                  id: TURN_ID,
                  items: [item],
                  status: 'completed',
                  error: null,
                },
              },
            });
          });
          return;
        default:
          // `initialized` is a notification: nothing answers it.
          return;
      }
    },
    onMessage(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    [Symbol.asyncIterator]() {
      return { next: () => Promise.resolve({ value: undefined, done: true }) };
    },
    async close() {
      listeners.clear();
    },
  };
}

function request(): ExecutionPlanRequest {
  return {
    text: 'Fix add so it returns the sum of both numbers.',
    engineeringPlanId: 'engineering-plan-155',
    filesToModify: [CALCULATOR],
  };
}

function approvalFor(
  plan: ExecutionPlan,
  digest = plan.contentDigest,
): ApprovalContract {
  const created = createApprovalContract({
    approvalId: 'approval-155',
    approvedBy: 'reviewer@example.com',
    approvalTimestamp: '2026-07-15T00:00:00.000Z',
    approvalType: 'ExecutionPlanApproval',
    notes: 'Approved for the vertical slice.',
    approvalStatus: ApprovalStatus.Approved,
    target: {
      targetType: ApprovalTargetType.ExecutionPlan,
      targetId: plan.executionPlanId,
      targetVersion: plan.version,
      targetContentDigest: digest,
    },
  });
  if (!created.ok) throw new Error(created.error.message);
  return created.value;
}

function track(report: VerticalSliceReport): VerticalSliceReport {
  live.add(report.sandbox);
  return report;
}

function readFixture(): Promise<string> {
  return readFile(path.join(SAMPLE_REPO_ROOT, CALCULATOR), 'utf8');
}

afterEach(async () => {
  await Promise.all([...live].map(async (handle) => disposeSandbox(handle)));
  live.clear();
});

describe('runVerticalSlice', () => {
  it(
    'plans, checks approval, edits and verifies an approved request',
    async () => {
      const client = createFakeClient({
        edits: [{ path: CALCULATOR, content: FIXED_CALCULATOR }],
      });

      const result = await runVerticalSlice({
        request: request(),
        repoId: SAMPLE_REPO_ID,
        approval: (plan) => approvalFor(plan),
        client,
      });

      expect(result.ok).toBe(true);
      if (!result.ok) return;
      const report = track(result.value);

      expect(report.status).toBe('Complete');
      expect(report.rolledBack).toBe(false);
      expect(report.appliedFiles).toEqual([CALCULATOR]);
      expect(report.planDigest).toBe(report.plan.contentDigest);
      expect(report.planDigest).toMatch(/^[0-9a-f]{64}$/);

      expect(report.diff).not.toBe('');
      expect(report.diff).toContain(CALCULATOR);
      expect(report.diff).toContain('-  return left - right;');
      expect(report.diff).toContain('+  return left + right;');

      expect(report.finalTests.success).toBe(true);
      expect(report.finalTests.command).toBe('npm test');
      expect(report.finalTests.exitCode).toBe(0);
      expect(report.finalTests.counts.failed).toBe(0);
      expect(report.finalTests.counts.passed).toBeGreaterThan(0);

      // The edit lives in the sandbox; the registered repo is untouched.
      expect(
        await readFile(path.join(report.sandbox.root, CALCULATOR), 'utf8'),
      ).toBe(FIXED_CALCULATOR);
      expect(await readFixture()).toContain('left - right');
    },
    TIMEOUT_MS,
  );

  it(
    'stops before any write when no approval is supplied',
    async () => {
      const before = await readFixture();
      const client = createFakeClient({
        edits: [{ path: CALCULATOR, content: FIXED_CALCULATOR }],
      });

      const result = await runVerticalSlice({
        request: request(),
        repoId: SAMPLE_REPO_ID,
        client,
      });

      expect(result).toEqual({
        ok: false,
        error: {
          code: 'EXECUTION_APPROVAL_MISSING',
          message: 'No approval was supplied for the execution plan',
        },
      });
      // Nothing was said to Codex at all: no handshake, no thread, no turn.
      expect(client.methods).toEqual([]);
      expect(await readFixture()).toBe(before);
    },
    TIMEOUT_MS,
  );

  it(
    'stops before any write when the approval is stale',
    async () => {
      const before = await readFixture();
      const client = createFakeClient({
        edits: [{ path: CALCULATOR, content: FIXED_CALCULATOR }],
      });

      const result = await runVerticalSlice({
        request: request(),
        repoId: SAMPLE_REPO_ID,
        // Approves a plan whose content is not the plan this run generated.
        approval: (plan) => approvalFor(plan, '0'.repeat(64)),
        client,
      });

      expect(result).toEqual({
        ok: false,
        error: {
          code: 'EXECUTION_APPROVAL_TARGET_CONTENT_DIGEST_MISMATCH',
          message:
            'Approval target content digest does not match the execution plan content digest',
        },
      });
      expect(client.methods).toEqual([]);
      expect(await readFixture()).toBe(before);
    },
    TIMEOUT_MS,
  );

  it(
    'refuses an approval granted for a different execution plan',
    async () => {
      const client = createFakeClient({
        edits: [{ path: CALCULATOR, content: FIXED_CALCULATOR }],
      });
      let generated: ExecutionPlan | undefined;

      const result = await runVerticalSlice({
        request: request(),
        repoId: SAMPLE_REPO_ID,
        approval: (plan) => {
          generated = plan;
          return approvalFor({
            ...plan,
            executionPlanId: '00000000-0000-4000-8000-000000000000',
          });
        },
        client,
      });

      expect(result).toMatchObject({
        ok: false,
        error: { code: 'EXECUTION_APPROVAL_TARGET_ID_MISMATCH' },
      });
      expect(generated).toBeDefined();
      expect(client.methods).toEqual([]);
    },
    TIMEOUT_MS,
  );

  it(
    'stops without editing when Codex has no usable credentials',
    async () => {
      const before = await readFixture();
      const client = createFakeClient({
        authMethod: null,
        edits: [{ path: CALCULATOR, content: FIXED_CALCULATOR }],
      });

      const result = await runVerticalSlice({
        request: request(),
        repoId: SAMPLE_REPO_ID,
        approval: (plan) => approvalFor(plan),
        client,
      });

      expect(result).toMatchObject({
        ok: false,
        error: { code: 'CODEX_AUTH_UNAVAILABLE' },
      });
      // Auth is proven before the edit turn, so no turn was ever started.
      expect(client.methods).not.toContain('turn/start');
      expect(await readFixture()).toBe(before);
    },
    TIMEOUT_MS,
  );

  it(
    'rolls the sandbox back when the edit fails verification',
    async () => {
      const client = createFakeClient({
        edits: [{ path: CALCULATOR, content: BROKEN_CALCULATOR }],
      });

      const result = await runVerticalSlice({
        request: request(),
        repoId: SAMPLE_REPO_ID,
        approval: (plan) => approvalFor(plan),
        client,
      });

      expect(result.ok).toBe(true);
      if (!result.ok) return;
      const report = track(result.value);

      expect(report.status).toBe('Failed');
      expect(report.rolledBack).toBe(true);
      expect(report.finalTests.success).toBe(false);
      expect(report.finalTests.counts.failed).toBeGreaterThan(0);
      // The diff still reports what was tried, even though it no longer exists.
      expect(report.diff).toContain('left * right');
      expect(
        await readFile(path.join(report.sandbox.root, CALCULATOR), 'utf8'),
      ).toContain('left - right');
    },
    TIMEOUT_MS,
  );
});
