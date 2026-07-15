import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

import type { ExecutionPlan } from '@codex-lens/shared';
import { afterEach, describe, expect, it } from 'vitest';

import { applyEdit } from '../src/codex/apply-edit.js';
import type {
  AppServerHandle,
  AppServerMessage,
} from '../src/codex/transport.js';
import { generateExecutionPlan } from '../src/plan-generation.js';
import { SAMPLE_REPO_ID } from '../src/registryConfig.js';
import {
  disposeSandbox,
  prepareSandbox,
  type SandboxHandle,
} from '../src/sandbox.js';

const TIMEOUT_MS = 60_000;
const THREAD_ID = '019f63c2-8b22-7613-89ce-023b27e0be00';
const TURN_ID = '019f63c2-8b22-7613-89ce-023b27e0be01';
const live = new Set<SandboxHandle>();

interface ScriptedClient extends AppServerHandle {
  sent: AppServerMessage[];
}

function createScriptedClient(
  items: readonly Record<string, unknown>[],
): ScriptedClient {
  const listeners = new Set<(message: AppServerMessage) => void>();
  const sent: AppServerMessage[] = [];
  const emit = (message: AppServerMessage): void => {
    for (const listener of [...listeners]) listener(message);
  };

  return {
    sent,
    async send(message) {
      sent.push(message);
      if (message.method !== 'turn/start') return;

      queueMicrotask(() => {
        emit({
          jsonrpc: '2.0',
          id: message.id,
          result: {
            turn: { id: TURN_ID, items: [], status: 'inProgress', error: null },
          },
        });
        for (const item of items) {
          emit({
            jsonrpc: '2.0',
            method: 'item/completed',
            params: { threadId: THREAD_ID, turnId: TURN_ID, item },
          });
        }
        emit({
          jsonrpc: '2.0',
          method: 'turn/completed',
          params: {
            threadId: THREAD_ID,
            turn: { id: TURN_ID, items: [...items], status: 'completed', error: null },
          },
        });
      });
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

async function sandbox(): Promise<SandboxHandle> {
  const prepared = await prepareSandbox(SAMPLE_REPO_ID);
  if (!prepared.ok) throw new Error(prepared.error.message);
  live.add(prepared.value);
  return prepared.value;
}

function plan(): ExecutionPlan {
  const generated = generateExecutionPlan(
    {
      text: 'Add a multiply helper and document it.',
      engineeringPlanId: 'engineering-plan-154',
      filesToModify: ['README.md'],
      filesToCreate: ['src/multiply.js'],
    },
    SAMPLE_REPO_ID,
  );
  if (!generated.ok) throw new Error(generated.error.message);
  return generated.value;
}

afterEach(async () => {
  await Promise.all([...live].map(async (handle) => disposeSandbox(handle)));
  live.clear();
});

describe('applyEdit', () => {
  it(
    'runs a read-only Codex turn and materializes agent edits in the sandbox',
    async () => {
      const handle = await sandbox();
      const client = createScriptedClient([
        {
          type: 'agentMessage',
          id: 'agent-1',
          text: JSON.stringify({
            edits: [
              {
                path: 'src/multiply.js',
                content: 'export const multiply = (a, b) => a * b;\n',
              },
              { path: 'README.md', content: '# Calculator\n\nNow with multiply.\n' },
            ],
          }),
        },
      ]);

      const result = await applyEdit(client, THREAD_ID, plan(), handle);

      expect(result).toEqual({
        ok: true,
        value: { changedFiles: ['src/multiply.js', 'README.md'] },
      });
      expect(
        await readFile(path.join(handle.root, 'src', 'multiply.js'), 'utf8'),
      ).toBe('export const multiply = (a, b) => a * b;\n');
      expect(await readFile(path.join(handle.root, 'README.md'), 'utf8')).toContain(
        'Now with multiply.',
      );

      expect(client.sent).toHaveLength(1);
      expect(client.sent[0]).toMatchObject({
        method: 'turn/start',
        params: {
          threadId: THREAD_ID,
          cwd: handle.root,
          approvalPolicy: 'never',
          sandboxPolicy: { type: 'readOnly', networkAccess: false },
        },
      });
    },
    TIMEOUT_MS,
  );

  it(
    'materializes a canned write-file tool call through the sandbox helper',
    async () => {
      const handle = await sandbox();
      const client = createScriptedClient([
        {
          type: 'dynamicToolCall',
          id: 'tool-1',
          tool: 'write_file',
          arguments: {
            path: 'src/multiply.js',
            content: 'export function multiply(a, b) { return a * b; }\n',
          },
        },
      ]);

      const result = await applyEdit(client, THREAD_ID, plan(), handle);

      expect(result).toEqual({
        ok: true,
        value: { changedFiles: ['src/multiply.js'] },
      });
      expect(
        await readFile(path.join(handle.root, 'src', 'multiply.js'), 'utf8'),
      ).toContain('return a * b');
    },
    TIMEOUT_MS,
  );

  it(
    'rejects an out-of-sandbox edit without creating the escaped file',
    async () => {
      const handle = await sandbox();
      const escaped = path.resolve(handle.root, '..', 'escaped-by-codex.txt');
      const client = createScriptedClient([
        {
          type: 'agentMessage',
          id: 'agent-escape',
          text: JSON.stringify({
            edits: [{ path: '../escaped-by-codex.txt', content: 'pwned\n' }],
          }),
        },
      ]);

      const result = await applyEdit(client, THREAD_ID, plan(), handle);

      expect(result).toMatchObject({
        ok: false,
        error: { code: 'SANDBOX_ESCAPE_REJECTED' },
      });
      expect(existsSync(escaped)).toBe(false);
    },
    TIMEOUT_MS,
  );
});
