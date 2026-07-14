import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

import { afterEach, describe, expect, it } from 'vitest';

import {
  startAppServer,
  type AppServerHandle,
} from '../src/codex/transport.js';

const handles = new Set<AppServerHandle>();
const echoFixture = fileURLToPath(
  new URL('./fixtures/echo-jsonl.mjs', import.meta.url),
);

afterEach(async () => {
  await Promise.all([...handles].map(async (handle) => handle.close()));
  handles.clear();
});

function startEchoServer(): AppServerHandle {
  const handle = startAppServer({
    command: process.execPath,
    args: [echoFixture],
  });
  handles.add(handle);
  return handle;
}

describe('Codex app-server stdio transport', () => {
  it('round-trips a newline-framed JSON message through a fake child', async () => {
    const handle = startEchoServer();
    const message = {
      method: 'thread/start',
      id: 10,
      params: { model: 'test-model' },
    };

    const received = new Promise((resolve) => {
      const unsubscribe = handle.onMessage((value) => {
        unsubscribe();
        resolve(value);
      });
    });

    await handle.send(message);

    await expect(received).resolves.toEqual(message);
  });

  it('also exposes received messages as an async iterator', async () => {
    const handle = startEchoServer();
    const message = { method: 'initialized', params: {} };
    const nextMessage = handle[Symbol.asyncIterator]().next();

    await handle.send(message);

    await expect(nextMessage).resolves.toEqual({ value: message, done: false });
  });

  it('uses CODEX_APP_SERVER_CMD as the configurable command path', async () => {
    const originalCommand = process.env.CODEX_APP_SERVER_CMD;
    process.env.CODEX_APP_SERVER_CMD = process.execPath;

    try {
      const handle = startAppServer({ args: [echoFixture] });
      handles.add(handle);
      const message = { id: 1, result: { ok: true } };
      const nextMessage = handle[Symbol.asyncIterator]().next();

      await handle.send(message);

      await expect(nextMessage).resolves.toEqual({
        value: message,
        done: false,
      });
    } finally {
      if (originalCommand === undefined) {
        delete process.env.CODEX_APP_SERVER_CMD;
      } else {
        process.env.CODEX_APP_SERVER_CMD = originalCommand;
      }
    }
  });

  it('only reads the command override and never accesses credential env vars', async () => {
    const sourcePath = fileURLToPath(
      new URL('../src/codex/transport.ts', import.meta.url),
    );
    const source = await readFile(sourcePath, 'utf8');
    const envReads = [...source.matchAll(/process\.env\.([A-Z0-9_]+)/g)].map(
      ([, name]) => name,
    );

    expect(envReads).toEqual(['CODEX_APP_SERVER_CMD']);
    expect(source).not.toMatch(/OPENAI_API_KEY|TOKEN|PASSWORD|SECRET/);
  });
});
