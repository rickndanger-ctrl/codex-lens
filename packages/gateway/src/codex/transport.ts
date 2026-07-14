import { spawn, type ChildProcessByStdio } from 'node:child_process';
import { createInterface } from 'node:readline';
import type { Readable, Writable } from 'node:stream';

export type AppServerMessage = Record<string, unknown>;
export type AppServerMessageListener = (message: AppServerMessage) => void;

export interface StartAppServerOptions {
  command?: string;
  args?: readonly string[];
  cwd?: string;
}

export interface AppServerHandle extends AsyncIterable<AppServerMessage> {
  send(message: AppServerMessage): Promise<void>;
  onMessage(listener: AppServerMessageListener): () => void;
  close(): Promise<void>;
}

type PendingMessage = {
  resolve: (result: IteratorResult<AppServerMessage>) => void;
  reject: (error: Error) => void;
};

const DEFAULT_COMMAND = 'codex';
const DEFAULT_ARGS = ['app-server'] as const;

/**
 * Starts Codex app-server over its default JSONL stdio transport.
 *
 * Set CODEX_APP_SERVER_CMD to override the `codex` binary path. The child
 * inherits the ambient local Codex environment; this module never reads,
 * prompts for, or logs credentials.
 */
export function startAppServer(
  options: StartAppServerOptions = {},
): AppServerHandle {
  const command =
    options.command ?? process.env.CODEX_APP_SERVER_CMD ?? DEFAULT_COMMAND;
  const args = options.args ?? DEFAULT_ARGS;
  const child = spawn(command, [...args], {
    cwd: options.cwd,
    shell: false,
    stdio: ['pipe', 'pipe', 'inherit'],
  });

  return createHandle(child);
}

function createHandle(
  child: ChildProcessByStdio<Writable, Readable, null>,
): AppServerHandle {
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const listeners = new Set<AppServerMessageListener>();
  const queuedMessages: AppServerMessage[] = [];
  const pendingMessages: PendingMessage[] = [];

  let terminalError: Error | undefined;
  let finished = false;
  let closing = false;
  let resolveChildClosed: () => void;
  const childClosed = new Promise<void>((resolve) => {
    resolveChildClosed = resolve;
  });

  // A write callback receives EPIPE, but streams also emit `error`. Keeping an
  // error listener installed prevents a send/close race with child death from
  // becoming an uncaught process-level exception.
  child.stdin.on('error', () => undefined);

  const finish = (error?: Error): void => {
    if (finished) {
      return;
    }
    finished = true;
    terminalError = error;
    lines.close();

    for (const pending of pendingMessages.splice(0)) {
      if (error !== undefined) {
        pending.reject(error);
      } else {
        pending.resolve({ value: undefined, done: true });
      }
    }
  };

  lines.on('line', (line) => {
    if (line.length === 0) {
      return;
    }

    let message: AppServerMessage;
    try {
      const parsed: unknown = JSON.parse(line);
      if (
        typeof parsed !== 'object' ||
        parsed === null ||
        Array.isArray(parsed)
      ) {
        throw new TypeError('message must be a JSON object');
      }
      message = parsed as AppServerMessage;
    } catch (cause) {
      finish(new Error('Codex app-server emitted invalid JSONL', { cause }));
      return;
    }

    for (const listener of listeners) {
      listener(message);
    }

    const pending = pendingMessages.shift();
    if (pending !== undefined) {
      pending.resolve({ value: message, done: false });
    } else {
      queuedMessages.push(message);
    }
  });

  child.once('error', (error) => finish(error));
  child.once('close', (code, signal) => {
    if (closing || code === 0) {
      finish();
    } else {
      const detail =
        signal === null ? `code ${String(code)}` : `signal ${signal}`;
      finish(new Error(`Codex app-server exited with ${detail}`));
    }

    resolveChildClosed();
  });

  const nextMessage = (): Promise<IteratorResult<AppServerMessage>> => {
    const queued = queuedMessages.shift();
    if (queued !== undefined) {
      return Promise.resolve({ value: queued, done: false });
    }
    if (terminalError !== undefined) {
      return Promise.reject(terminalError);
    }
    if (finished) {
      return Promise.resolve({ value: undefined, done: true });
    }

    return new Promise((resolve, reject) => {
      pendingMessages.push({ resolve, reject });
    });
  };

  return {
    async send(message) {
      if (closing || finished) {
        throw new Error('Codex app-server transport is closed');
      }

      const frame = `${JSON.stringify(message)}\n`;
      await new Promise<void>((resolve, reject) => {
        child.stdin.write(frame, (error) => {
          if (error !== null && error !== undefined) {
            reject(error);
          } else {
            resolve();
          }
        });
      });
    },

    onMessage(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },

    [Symbol.asyncIterator]() {
      return { next: nextMessage };
    },

    async close() {
      if (closing) {
        await childClosed;
        return;
      }

      closing = true;
      if (!child.stdin.destroyed) {
        child.stdin.end();
      }
      if (child.exitCode === null && child.signalCode === null) {
        child.kill();
      }
      await childClosed;
    },
  };
}
