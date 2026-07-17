import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { GATEWAY_TOKEN_ENV } from '../src/auth/index.js';
import { openDb, type Db } from '../src/db/schema.js';
import {
  createOpenAiRealtimeIssuer,
  OPENAI_API_KEY_ENV,
  realtimeIssuerFromEnv,
  REALTIME_CREDENTIALS_PATH,
  RealtimeCredentialSchema,
  type RealtimeCredential,
  type RealtimeCredentialIssuer,
} from '../src/realtime/credentials.js';
import { buildServer } from '../src/server.js';

const TEST_TOKEN = 'realtime-test-token';
const AUTH_HEADERS = { authorization: `Bearer ${TEST_TOKEN}` };

const servers = new Set<ReturnType<typeof buildServer>>();
const dbs = new Set<Db>();
let originalToken: string | undefined;
let originalKey: string | undefined;

beforeEach(() => {
  originalToken = process.env[GATEWAY_TOKEN_ENV];
  originalKey = process.env[OPENAI_API_KEY_ENV];
  process.env[GATEWAY_TOKEN_ENV] = TEST_TOKEN;
  // Never let a real key in the environment reach these tests.
  delete process.env[OPENAI_API_KEY_ENV];
});

afterEach(async () => {
  await Promise.all([...servers].map(async (server) => server.close()));
  servers.clear();
  for (const db of dbs) {
    db.close();
  }
  dbs.clear();
  restore(GATEWAY_TOKEN_ENV, originalToken);
  restore(OPENAI_API_KEY_ENV, originalKey);
});

function restore(name: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}

function makeServer(
  issuer: RealtimeCredentialIssuer | undefined,
): ReturnType<typeof buildServer> {
  const db = openDb(':memory:');
  dbs.add(db);
  const server = buildServer(
    issuer === undefined
      ? { db }
      : { db, realtimeCredentialIssuer: issuer },
  );
  servers.add(server);
  return server;
}

const CREDENTIAL: RealtimeCredential = {
  value: 'ephemeral-secret-123',
  expiresAt: '2026-07-16T12:00:00.000Z',
  model: 'gpt-realtime',
  sessionId: 'sess_abc',
};

describe('POST /v1/realtime/credentials', () => {
  it('returns 401 without a token', async () => {
    const server = makeServer(async () => ({ ok: true, value: CREDENTIAL }));

    const response = await server.inject({
      method: 'POST',
      url: REALTIME_CREDENTIALS_PATH,
      payload: {},
    });

    expect(response.statusCode).toBe(401);
  });

  it('issues a short-lived credential from the injected issuer', async () => {
    let received: unknown;
    const server = makeServer(async (request) => {
      received = request;
      return { ok: true, value: CREDENTIAL };
    });

    const response = await server.inject({
      method: 'POST',
      url: REALTIME_CREDENTIALS_PATH,
      headers: AUTH_HEADERS,
      payload: { model: 'gpt-realtime' },
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(RealtimeCredentialSchema.safeParse(body).success).toBe(true);
    expect(body).toEqual(CREDENTIAL);
    expect(received).toEqual({ model: 'gpt-realtime' });
  });

  it('accepts a body with no model (server picks the default)', async () => {
    const server = makeServer(async () => ({ ok: true, value: CREDENTIAL }));

    const response = await server.inject({
      method: 'POST',
      url: REALTIME_CREDENTIALS_PATH,
      headers: AUTH_HEADERS,
      payload: {},
    });

    expect(response.statusCode).toBe(200);
  });

  it('rejects an unknown field with 400', async () => {
    const server = makeServer(async () => ({ ok: true, value: CREDENTIAL }));

    const response = await server.inject({
      method: 'POST',
      url: REALTIME_CREDENTIALS_PATH,
      headers: AUTH_HEADERS,
      payload: { model: 'gpt-realtime', apiKey: 'leak-attempt' },
    });

    expect(response.statusCode).toBe(400);
  });

  it('fails closed with 503 when no issuer is configured', async () => {
    const server = makeServer(undefined);

    const response = await server.inject({
      method: 'POST',
      url: REALTIME_CREDENTIALS_PATH,
      headers: AUTH_HEADERS,
      payload: {},
    });

    expect(response.statusCode).toBe(503);
  });

  it('returns 503 (not a 500) when the issuer fails, leaking no detail', async () => {
    const server = makeServer(async () => ({
      ok: false,
      error: { code: 'REALTIME_ISSUER_REJECTED', message: 'upstream 429 rate limited' },
    }));

    const response = await server.inject({
      method: 'POST',
      url: REALTIME_CREDENTIALS_PATH,
      headers: AUTH_HEADERS,
      payload: {},
    });

    expect(response.statusCode).toBe(503);
    expect(response.body).not.toContain('429');
    expect(response.body).not.toContain('upstream');
  });
});

describe('createOpenAiRealtimeIssuer', () => {
  function stubFetch(
    impl: (url: string, init: RequestInit) => Response | Promise<Response>,
  ): typeof fetch {
    return (async (input: RequestInfo | URL, init?: RequestInit) =>
      impl(String(input), init ?? {})) as unknown as typeof fetch;
  }

  it('exchanges the long-lived key for an ephemeral one; the key never returns to the caller', async () => {
    let sentAuth: string | undefined;
    let sentBody: unknown;
    const issuer = createOpenAiRealtimeIssuer({
      apiKey: 'sk-long-lived-SECRET',
      fetchImpl: stubFetch((_url, init) => {
        sentAuth = (init.headers as Record<string, string>).authorization;
        sentBody = JSON.parse(String(init.body));
        return new Response(
          JSON.stringify({
            id: 'sess_xyz',
            model: 'gpt-realtime',
            client_secret: { value: 'ek_ephemeral', expires_at: 1_784_000_000 },
          }),
          { status: 200 },
        );
      }),
    });

    const result = await issuer({ model: 'gpt-realtime' });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    // The long-lived key went upstream, never into the returned credential.
    expect(sentAuth).toBe('Bearer sk-long-lived-SECRET');
    expect(sentBody).toEqual({ model: 'gpt-realtime' });
    expect(result.value.value).toBe('ek_ephemeral');
    expect(result.value.sessionId).toBe('sess_xyz');
    // 1_784_000_000 unix seconds, converted to ISO.
    expect(result.value.expiresAt).toBe(
      new Date(1_784_000_000 * 1000).toISOString(),
    );
    expect(JSON.stringify(result.value)).not.toContain('sk-long-lived-SECRET');
  });

  it('maps a non-2xx upstream to a rejected result without the upstream body', async () => {
    const issuer = createOpenAiRealtimeIssuer({
      apiKey: 'sk-x',
      fetchImpl: stubFetch(() => new Response('quota exceeded', { status: 429 })),
    });

    const result = await issuer({});

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe('REALTIME_ISSUER_REJECTED');
    expect(result.error.message).not.toContain('quota');
  });

  it('rejects a malformed upstream response', async () => {
    const issuer = createOpenAiRealtimeIssuer({
      apiKey: 'sk-x',
      fetchImpl: stubFetch(
        () => new Response(JSON.stringify({ nope: true }), { status: 200 }),
      ),
    });

    const result = await issuer({});

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe('REALTIME_ISSUER_BAD_RESPONSE');
  });

  it('surfaces a network failure as unreachable', async () => {
    const issuer = createOpenAiRealtimeIssuer({
      apiKey: 'sk-x',
      fetchImpl: stubFetch(() => {
        throw new Error('ECONNREFUSED');
      }),
    });

    const result = await issuer({});

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe('REALTIME_ISSUER_UNREACHABLE');
  });
});

describe('realtimeIssuerFromEnv', () => {
  it('is undefined when no key is set (route then fails closed)', () => {
    expect(realtimeIssuerFromEnv({})).toBeUndefined();
    expect(realtimeIssuerFromEnv({ [OPENAI_API_KEY_ENV]: '' })).toBeUndefined();
  });

  it('builds an issuer when the key is present', () => {
    expect(
      realtimeIssuerFromEnv({ [OPENAI_API_KEY_ENV]: 'sk-present' }),
    ).toBeTypeOf('function');
  });
});
