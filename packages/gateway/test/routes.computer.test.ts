import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { err, ok } from '@codex-lens/shared';

import { GATEWAY_TOKEN_ENV } from '../src/auth/index.js';
import type { ComputerActionRequest } from '../src/computer/codexComputer.js';
import { buildServer } from '../src/server.js';

const TOKEN = 'computer-route-test-token';
let originalToken: string | undefined;

beforeEach(() => {
  originalToken = process.env[GATEWAY_TOKEN_ENV];
  process.env[GATEWAY_TOKEN_ENV] = TOKEN;
});

afterEach(() => {
  if (originalToken === undefined) delete process.env[GATEWAY_TOKEN_ENV];
  else process.env[GATEWAY_TOKEN_ENV] = originalToken;
});

describe('POST /v1/computer/inspect', () => {
  it('authenticates, validates, and returns a read-only inspection', async () => {
    const server = buildServer({
      computerInspector: async (request) => ok({
        app: request.app,
        summary: `Visible: ${request.question}`,
      }),
    });
    const response = await server.inject({
      method: 'POST',
      url: '/v1/computer/inspect',
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: { app: 'Xcode', question: 'What project is open?' },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      app: 'Xcode',
      summary: 'Visible: What project is open?',
    });
    await server.close();
  });

  it('rejects extra fields and maps broker failure without leaking detail', async () => {
    const server = buildServer({
      computerInspector: async () => err('PRIVATE_DETAIL', 'Inspection unavailable.'),
    });
    const invalid = await server.inject({
      method: 'POST',
      url: '/v1/computer/inspect',
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: { app: 'Xcode', question: 'Inspect', click: true },
    });
    expect(invalid.statusCode).toBe(400);

    const unavailable = await server.inject({
      method: 'POST',
      url: '/v1/computer/inspect',
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: { app: 'Xcode', question: 'Inspect' },
    });
    expect(unavailable.statusCode).toBe(503);
    expect(unavailable.json()).toMatchObject({ message: 'Inspection unavailable.' });
    await server.close();
  });
});

describe('GET /v1/computer/frontmost', () => {
  it('returns only the active app name through the read-only fast path', async () => {
    const server = buildServer({
      frontmostComputerAppReader: async () => ok({ app: 'ChatGPT' }),
    });
    const response = await server.inject({
      method: 'GET',
      url: '/v1/computer/frontmost',
      headers: { authorization: `Bearer ${TOKEN}` },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ app: 'ChatGPT', readOnly: true });
    await server.close();
  });

  it('fails closed when macOS cannot identify the active app', async () => {
    const server = buildServer({
      frontmostComputerAppReader: async () => err(
        'FRONTMOST_APP_UNAVAILABLE',
        'The active Mac app could not be read.',
      ),
    });
    const response = await server.inject({
      method: 'GET',
      url: '/v1/computer/frontmost',
      headers: { authorization: `Bearer ${TOKEN}` },
    });

    expect(response.statusCode).toBe(503);
    expect(response.json()).toMatchObject({
      message: 'The active Mac app could not be read.',
    });
    await server.close();
  });
});

describe('computer action routes', () => {
  it('runs an ordinary reversible action directly with ordinary authority', async () => {
    const control = vi.fn(async (request: ComputerActionRequest) => ok({
      completed: true,
      confirmationRequired: false,
      summary: `Completed: ${request.instruction}`,
      surface: request.surface,
    }));
    const server = buildServer({ computerController: control });
    const response = await server.inject({
      method: 'POST',
      url: '/v1/computer/use',
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: { instruction: 'Bring Xcode to the front.', surface: 'computer' },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      completed: true,
      confirmationRequired: false,
      summary: 'Completed: Bring Xcode to the front.',
      surface: 'computer',
    });
    expect(control).toHaveBeenCalledOnce();
    expect(control).toHaveBeenCalledWith({
      instruction: 'Bring Xcode to the front.',
      surface: 'computer',
      authorization: 'ordinary',
    });
    await server.close();
  });

  it('prepares without acting, then executes the exact confirmed action once', async () => {
    const control = vi.fn(async (request: ComputerActionRequest) => ok({
      completed: true,
      confirmationRequired: false,
      summary: `Completed: ${request.instruction}`,
      surface: request.surface,
    }));
    const server = buildServer({
      computerController: control,
    });
    const prepared = await server.inject({
      method: 'POST',
      url: '/v1/computer/prepare',
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: { instruction: 'Open Xcode and show the current build issue.', surface: 'computer' },
    });
    expect(prepared.statusCode).toBe(200);
    expect(prepared.json()).toMatchObject({
      instruction: 'Open Xcode and show the current build issue.',
      surface: 'computer',
      requiresExplicitConfirmation: true,
    });
    expect(prepared.json().digest).toMatch(/^[a-f0-9]{64}$/u);
    expect(control).not.toHaveBeenCalled();

    const response = await server.inject({
      method: 'POST',
      url: '/v1/computer/execute',
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: {
        confirmationId: prepared.json().confirmationId,
        digest: prepared.json().digest,
      },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      completed: true,
      confirmationRequired: false,
      summary: 'Completed: Open Xcode and show the current build issue.',
      surface: 'computer',
    });
    expect(control).toHaveBeenCalledOnce();
    expect(control).toHaveBeenCalledWith({
      instruction: 'Open Xcode and show the current build issue.',
      surface: 'computer',
      authorization: 'confirmed',
    });
    await server.close();
  });

  it('defaults to auto and rejects unknown surfaces', async () => {
    const control = vi.fn(async () => ok({
      completed: true,
      confirmationRequired: false,
      summary: 'Completed.',
      surface: 'auto' as const,
    }));
    const server = buildServer({ computerController: control });
    const defaulted = await server.inject({
      method: 'POST',
      url: '/v1/computer/prepare',
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: { instruction: 'Prepare the requested action.' },
    });
    expect(defaulted.statusCode).toBe(200);
    expect(defaulted.json()).toMatchObject({
      requiresExplicitConfirmation: true,
      surface: 'auto',
    });
    expect(control).not.toHaveBeenCalled();

    const invalid = await server.inject({
      method: 'POST',
      url: '/v1/computer/prepare',
      headers: { authorization: `Bearer ${TOKEN}` },
      payload: { instruction: 'Do something.', surface: 'unrestricted' },
    });
    expect(invalid.statusCode).toBe(400);
    await server.close();
  });
});
