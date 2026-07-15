import { randomUUID } from 'node:crypto';

import {
  err,
  ok,
  type ExecutionPlan,
  type Result,
} from '@codex-lens/shared';

import {
  validateSandboxWrite,
  writeFileInSandbox,
  type SandboxHandle,
} from '../sandbox.js';
import { CODEX_AUTH_UNAVAILABLE, isAuthUnavailable } from './client.js';
import type { AppServerHandle, AppServerMessage } from './transport.js';

const TURN_TIMEOUT_MS = 30_000;

export interface AppliedEdit {
  /** Sandbox-relative paths successfully materialized by this turn. */
  changedFiles: string[];
}

interface PendingEdit {
  path: string;
  content: string;
}

interface TurnOutcome {
  messages: AppServerMessage[];
  turn: Record<string, unknown>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function turnInstructions(executionPlan: ExecutionPlan): string {
  return [
    'Implement the execution plan below.',
    'Inspect files as needed, but do not use file-writing tools or shell commands that change files.',
    'Return only JSON in this exact shape: {"edits":[{"path":"repo/relative/path","content":"complete replacement content"}]}.',
    'Every path must be relative to the working directory. Include the complete final UTF-8 content for every created or modified file.',
    'Execution plan:',
    JSON.stringify(executionPlan),
  ].join('\n');
}

/**
 * Starts a read-only Codex turn and captures its response traffic through turn
 * completion. Read-only is intentional: Codex may inspect the sandbox, but the
 * adapter remains the only component allowed to materialize an edit.
 */
async function runTurn(
  client: AppServerHandle,
  threadId: string,
  executionPlan: ExecutionPlan,
  sandbox: SandboxHandle,
): Promise<Result<TurnOutcome>> {
  const requestId = `apply-edit-${randomUUID()}`;
  const messages: AppServerMessage[] = [];

  return new Promise((resolve) => {
    let settled = false;
    let turn: Record<string, unknown> | undefined;
    const completions = new Map<string, AppServerMessage>();

    const settle = (result: Result<TurnOutcome>): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      unsubscribe();
      resolve(result);
    };

    const finishIfReady = (): void => {
      if (turn === undefined || typeof turn.id !== 'string') return;
      const completed = completions.get(turn.id);
      if (completed === undefined) return;
      const completedParams = completed.params;
      const completedTurn = isRecord(completedParams)
        ? completedParams.turn
        : undefined;
      if (!isRecord(completedTurn)) return;
      turn = completedTurn;
      settle(ok({ messages, turn }));
    };

    const timer = setTimeout(() => {
      settle(
        err(
          'CODEX_TURN_TIMED_OUT',
          `Codex did not complete the edit turn within ${TURN_TIMEOUT_MS}ms`,
        ),
      );
    }, TURN_TIMEOUT_MS);
    timer.unref();

    const unsubscribe = client.onMessage((message) => {
      messages.push(message);

      if (message.id === requestId) {
        if (isRecord(message.error)) {
          const detail =
            typeof message.error.message === 'string'
              ? message.error.message
              : 'Codex rejected the edit turn';
          settle(
            isAuthUnavailable(message.error.code, detail)
              ? err(
                  CODEX_AUTH_UNAVAILABLE,
                  `Codex authentication is unavailable: ${detail}`,
                )
              : err('CODEX_TURN_FAILED', detail),
          );
          return;
        }
        const result = message.result;
        const responseTurn = isRecord(result) ? result.turn : undefined;
        if (!isRecord(responseTurn) || typeof responseTurn.id !== 'string') {
          settle(
            err(
              'CODEX_PROTOCOL_ERROR',
              'Codex answered "turn/start" without a turn id',
            ),
          );
          return;
        }
        turn = responseTurn;
        finishIfReady();
        return;
      }

      if (message.method !== 'turn/completed' || !isRecord(message.params)) {
        return;
      }
      if (message.params.threadId !== threadId) return;

      const notificationTurn = message.params.turn;
      if (!isRecord(notificationTurn) || typeof notificationTurn.id !== 'string') {
        return;
      }
      if (turn !== undefined && notificationTurn.id !== turn.id) return;
      completions.set(notificationTurn.id, message);
      finishIfReady();
    });

    client
      .send({
        jsonrpc: '2.0',
        id: requestId,
        method: 'turn/start',
        params: {
          threadId,
          input: [
            {
              type: 'text',
              text: turnInstructions(executionPlan),
              text_elements: [],
            },
          ],
          cwd: sandbox.root,
          approvalPolicy: 'never',
          sandboxPolicy: { type: 'readOnly', networkAccess: false },
          outputSchema: {
            type: 'object',
            additionalProperties: false,
            required: ['edits'],
            properties: {
              edits: {
                type: 'array',
                items: {
                  type: 'object',
                  additionalProperties: false,
                  required: ['path', 'content'],
                  properties: {
                    path: { type: 'string', minLength: 1 },
                    content: { type: 'string' },
                  },
                },
              },
            },
          },
        },
      })
      .catch((error: unknown) => {
        settle(
          err(
            'CODEX_TRANSPORT_FAILED',
            `Could not start the Codex edit turn: ${errorMessage(error)}`,
          ),
        );
      });
  });
}

function parseJson(text: string): unknown {
  const trimmed = text.trim();
  const fenced = /^```(?:json)?\s*([\s\S]*?)\s*```$/iu.exec(trimmed);
  return JSON.parse(fenced?.[1] ?? trimmed) as unknown;
}

function readEdit(value: unknown): PendingEdit | undefined {
  if (!isRecord(value)) return undefined;
  const editPath = value.path ?? value.relPath;
  if (typeof editPath !== 'string' || typeof value.content !== 'string') {
    return undefined;
  }
  return { path: editPath, content: value.content };
}

function readEdits(value: unknown): PendingEdit[] | undefined {
  if (!isRecord(value) || !Array.isArray(value.edits)) return undefined;
  const edits = value.edits.map(readEdit);
  return edits.every((edit): edit is PendingEdit => edit !== undefined)
    ? edits
    : undefined;
}

function editsFromItem(item: unknown): Result<PendingEdit[]> {
  if (!isRecord(item)) return ok([]);

  if (item.type === 'agentMessage' && typeof item.text === 'string') {
    try {
      const edits = readEdits(parseJson(item.text));
      return edits === undefined ? ok([]) : ok(edits);
    } catch {
      // Progress and commentary agent messages are allowed. A valid structured
      // final message is still required before the turn can succeed.
      return ok([]);
    }
  }

  if (item.type === 'dynamicToolCall') {
    const tool = typeof item.tool === 'string' ? item.tool : '';
    if (!/^(?:write_?file(?:_in_sandbox)?|apply_?edit)$/iu.test(tool)) {
      return ok([]);
    }
    let args: unknown = item.arguments;
    if (typeof args === 'string') {
      try {
        args = parseJson(args);
      } catch {
        return err('CODEX_EDIT_INVALID', `Codex tool call "${tool}" had invalid JSON arguments`);
      }
    }
    const many = readEdits(args);
    if (many !== undefined) return ok(many);
    const one = readEdit(args);
    return one === undefined
      ? err('CODEX_EDIT_INVALID', `Codex tool call "${tool}" did not contain a path and content`)
      : ok([one]);
  }

  return ok([]);
}

function completedItems(outcome: TurnOutcome, threadId: string): unknown[] {
  const items: unknown[] = [];
  const seen = new Set<string>();

  const add = (item: unknown): void => {
    const id = isRecord(item) && typeof item.id === 'string' ? item.id : undefined;
    if (id !== undefined && seen.has(id)) return;
    if (id !== undefined) seen.add(id);
    items.push(item);
  };

  for (const message of outcome.messages) {
    if (message.method !== 'item/completed' || !isRecord(message.params)) continue;
    if (message.params.threadId !== threadId) continue;
    if (message.params.turnId !== outcome.turn.id) continue;
    add(message.params.item);
  }

  if (Array.isArray(outcome.turn.items)) {
    for (const item of outcome.turn.items) add(item);
  }
  return items;
}

/**
 * Executes an approved plan on an existing Codex thread, then materializes the
 * returned full-file edits through the sandbox's sole authorized write path.
 */
export async function applyEdit(
  client: AppServerHandle,
  threadId: string,
  executionPlan: ExecutionPlan,
  sandbox: SandboxHandle,
): Promise<Result<AppliedEdit>> {
  if (threadId.trim().length === 0) {
    return err('INVALID_THREAD_ID', 'Thread id must not be empty');
  }

  const outcome = await runTurn(client, threadId, executionPlan, sandbox);
  if (!outcome.ok) return outcome;

  const status = outcome.value.turn.status;
  if (status !== 'completed') {
    const failure = isRecord(outcome.value.turn.error)
      ? outcome.value.turn.error.message
      : undefined;
    return err(
      'CODEX_TURN_FAILED',
      typeof failure === 'string' ? failure : `Codex edit turn ended with status "${String(status)}"`,
    );
  }

  const edits = new Map<string, string>();
  for (const item of completedItems(outcome.value, threadId)) {
    const parsed = editsFromItem(item);
    if (!parsed.ok) return parsed;
    for (const edit of parsed.value) edits.set(edit.path, edit.content);
  }

  if (edits.size === 0) {
    return err('CODEX_EDIT_MISSING', 'Codex completed the turn without returning any file edits');
  }

  for (const editPath of edits.keys()) {
    const validated = await validateSandboxWrite(sandbox, editPath);
    if (!validated.ok) return validated;
  }

  const changedFiles: string[] = [];
  for (const [editPath, content] of edits) {
    const written = await writeFileInSandbox(sandbox, editPath, content);
    if (!written.ok) return written;
    changedFiles.push(editPath);
  }

  return ok({ changedFiles });
}
