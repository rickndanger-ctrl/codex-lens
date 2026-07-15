import { describe, expect, it } from 'vitest';

import {
  CODEX_AUTH_UNAVAILABLE,
  createThread,
  initialize,
  resumeThread,
} from '../src/codex/client.js';
import type {
  AppServerHandle,
  AppServerMessage,
} from '../src/codex/transport.js';

type Script = Record<
  string,
  (request: AppServerMessage) => AppServerMessage | undefined
>;

interface FakeTransport extends AppServerHandle {
  /** Every frame the client wrote, in order. */
  sent: AppServerMessage[];
  /** Pushes an unsolicited frame at the client, as the real server may. */
  emit(message: AppServerMessage): void;
}

/**
 * A transport whose canned answers are keyed by method. A script entry may
 * return `undefined` to model a server that never answers.
 */
function createFakeTransport(
  script: Script,
  options: { sendError?: Error } = {},
): FakeTransport {
  const listeners = new Set<(message: AppServerMessage) => void>();
  const sent: AppServerMessage[] = [];

  const emit = (message: AppServerMessage): void => {
    for (const listener of [...listeners]) {
      listener(message);
    }
  };

  return {
    sent,
    emit,

    async send(message) {
      if (options.sendError !== undefined) {
        throw options.sendError;
      }
      sent.push(message);

      const reply = script[String(message.method)]?.(message);
      if (reply !== undefined) {
        // Answers arrive on a later tick, as they would over a real pipe.
        queueMicrotask(() => emit(reply));
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

const okInit = (request: AppServerMessage): AppServerMessage => ({
  jsonrpc: '2.0',
  id: request.id,
  result: { userAgent: 'codex/1.4.0 (app-server)', authMethod: 'chatgpt' },
});

const okStart = (request: AppServerMessage): AppServerMessage => ({
  jsonrpc: '2.0',
  id: request.id,
  result: { threadId: 'thread_01H8XYZ' },
});

const okResume = (request: AppServerMessage): AppServerMessage => ({
  jsonrpc: '2.0',
  id: request.id,
  result: {
    threadId: String((request.params as { threadId?: unknown }).threadId),
  },
});

const authError = (request: AppServerMessage): AppServerMessage => ({
  jsonrpc: '2.0',
  id: request.id,
  error: {
    code: 'auth_required',
    message: 'No Codex credentials found; run `codex login`',
  },
});

describe('initialize', () => {
  it('handshakes and reports the active auth method', async () => {
    const transport = createFakeTransport({ initialize: okInit });

    const result = await initialize(transport);

    expect(result).toEqual({
      ok: true,
      value: { userAgent: 'codex/1.4.0 (app-server)', authMethod: 'chatgpt' },
    });
    expect(transport.sent[0]).toMatchObject({
      jsonrpc: '2.0',
      method: 'initialize',
      params: { clientInfo: { name: '@codex-lens/gateway' } },
    });
    expect(transport.sent[0]?.id).toEqual(expect.any(Number));
  });

  it('acknowledges the handshake with an initialized notification', async () => {
    const transport = createFakeTransport({ initialize: okInit });

    await initialize(transport);

    expect(transport.sent[1]).toEqual({
      jsonrpc: '2.0',
      method: 'initialized',
      params: {},
    });
  });

  it('fails with the auth code when the app-server reports no credentials', async () => {
    const transport = createFakeTransport({ initialize: authError });

    const result = await initialize(transport);

    expect(result.ok).toBe(false);
    expect(result).toMatchObject({
      error: {
        code: CODEX_AUTH_UNAVAILABLE,
        message: expect.stringContaining('codex login'),
      },
    });
    // Never acknowledge a handshake that did not establish auth.
    expect(transport.sent).toHaveLength(1);
  });

  it('fails with the auth code when the result reports no active auth method', async () => {
    const transport = createFakeTransport({
      initialize: (request) => ({
        jsonrpc: '2.0',
        id: request.id,
        result: { userAgent: 'codex/1.4.0', authMethod: null },
      }),
    });

    const result = await initialize(transport);

    expect(result).toMatchObject({
      ok: false,
      error: { code: CODEX_AUTH_UNAVAILABLE },
    });
  });

  it('fails with the auth code when the result reports an unauthenticated session', async () => {
    const transport = createFakeTransport({
      initialize: (request) => ({
        jsonrpc: '2.0',
        id: request.id,
        result: { authenticated: false },
      }),
    });

    const result = await initialize(transport);

    expect(result).toMatchObject({
      ok: false,
      error: { code: CODEX_AUTH_UNAVAILABLE },
    });
  });

  it('recognizes an auth failure stated only in the error message', async () => {
    const transport = createFakeTransport({
      initialize: (request) => ({
        jsonrpc: '2.0',
        id: request.id,
        error: { code: -32000, message: 'You are not logged in to Codex' },
      }),
    });

    const result = await initialize(transport);

    expect(result).toMatchObject({
      ok: false,
      error: { code: CODEX_AUTH_UNAVAILABLE },
    });
  });

  it('reports an unrelated rejection under its own code', async () => {
    const transport = createFakeTransport({
      initialize: (request) => ({
        jsonrpc: '2.0',
        id: request.id,
        error: { code: -32601, message: 'Method not found' },
      }),
    });

    const result = await initialize(transport);

    expect(result).toMatchObject({
      ok: false,
      error: {
        code: 'CODEX_REQUEST_FAILED',
        message: expect.stringContaining('Method not found'),
      },
    });
  });
});

describe('createThread', () => {
  it('starts a thread and returns its id', async () => {
    const transport = createFakeTransport({ 'thread/start': okStart });

    const result = await createThread(transport);

    expect(result).toEqual({ ok: true, value: { threadId: 'thread_01H8XYZ' } });
    expect(transport.sent[0]).toMatchObject({
      jsonrpc: '2.0',
      method: 'thread/start',
      params: {},
    });
  });

  it('passes cwd and model through when given', async () => {
    const transport = createFakeTransport({ 'thread/start': okStart });

    await createThread(transport, { cwd: '/repo', model: 'gpt-5-codex' });

    expect(transport.sent[0]?.params).toEqual({
      cwd: '/repo',
      model: 'gpt-5-codex',
    });
  });

  it('fails with the auth code rather than fabricating a thread', async () => {
    const transport = createFakeTransport({ 'thread/start': authError });

    const result = await createThread(transport);

    expect(result).toMatchObject({
      ok: false,
      error: { code: CODEX_AUTH_UNAVAILABLE },
    });
  });

  it('rejects a response with no thread id', async () => {
    const transport = createFakeTransport({
      'thread/start': (request) => ({
        jsonrpc: '2.0',
        id: request.id,
        result: { thread: {} },
      }),
    });

    const result = await createThread(transport);

    expect(result).toMatchObject({
      ok: false,
      error: { code: 'CODEX_PROTOCOL_ERROR' },
    });
  });
});

describe('resumeThread', () => {
  it('resumes an existing thread by id', async () => {
    const transport = createFakeTransport({ 'thread/resume': okResume });

    const result = await resumeThread(transport, 'thread_01H8XYZ');

    expect(result).toEqual({ ok: true, value: { threadId: 'thread_01H8XYZ' } });
    expect(transport.sent[0]).toMatchObject({
      jsonrpc: '2.0',
      method: 'thread/resume',
      params: { threadId: 'thread_01H8XYZ' },
    });
  });

  it('fails with the auth code rather than fabricating a resume', async () => {
    const transport = createFakeTransport({ 'thread/resume': authError });

    const result = await resumeThread(transport, 'thread_01H8XYZ');

    expect(result).toMatchObject({
      ok: false,
      error: { code: CODEX_AUTH_UNAVAILABLE },
    });
  });

  it('rejects an empty thread id without touching the transport', async () => {
    const transport = createFakeTransport({ 'thread/resume': okResume });

    const result = await resumeThread(transport, '');

    expect(result).toMatchObject({
      ok: false,
      error: { code: 'INVALID_THREAD_ID' },
    });
    expect(transport.sent).toHaveLength(0);
  });
});

describe('request handling', () => {
  it('ignores unrelated traffic while waiting for its own response', async () => {
    const transport = createFakeTransport({
      'thread/start': (request) => {
        queueMicrotask(() => {
          transport.emit({ jsonrpc: '2.0', method: 'codex/event', params: {} });
          transport.emit({
            jsonrpc: '2.0',
            id: 9999,
            result: { threadId: 'x' },
          });
        });
        return okStart(request);
      },
    });

    const result = await createThread(transport);

    expect(result).toEqual({ ok: true, value: { threadId: 'thread_01H8XYZ' } });
  });

  it('uses a distinct request id per call', async () => {
    const transport = createFakeTransport({ 'thread/start': okStart });

    await createThread(transport);
    await createThread(transport);

    expect(transport.sent[0]?.id).not.toBe(transport.sent[1]?.id);
  });

  it('times out instead of hanging when the app-server never answers', async () => {
    const transport = createFakeTransport({ 'thread/start': () => undefined });

    const result = await createThread(transport, { timeoutMs: 10 });

    expect(result).toMatchObject({
      ok: false,
      error: { code: 'CODEX_REQUEST_TIMED_OUT' },
    });
  });

  it('returns a Failed Result when the transport cannot send', async () => {
    const transport = createFakeTransport(
      { 'thread/start': okStart },
      { sendError: new Error('Codex app-server transport is closed') },
    );

    const result = await createThread(transport);

    expect(result).toMatchObject({
      ok: false,
      error: {
        code: 'CODEX_TRANSPORT_FAILED',
        message: expect.stringContaining('transport is closed'),
      },
    });
  });
});
