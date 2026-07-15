import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import type { FastifyListenOptions } from 'fastify';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MockInstance } from 'vitest';

import { GATEWAY_TOKEN_ENV } from '../src/auth/index.js';
import { GATEWAY_HOST, start } from '../src/index.js';
import { buildServer } from '../src/server.js';

const TEST_TOKEN = 'security-posture-test-token';

const servers = new Set<ReturnType<typeof buildServer>>();
let originalToken: string | undefined;

beforeEach(() => {
  originalToken = process.env[GATEWAY_TOKEN_ENV];
  process.env[GATEWAY_TOKEN_ENV] = TEST_TOKEN;
});

afterEach(async () => {
  if (originalToken === undefined) {
    delete process.env[GATEWAY_TOKEN_ENV];
  } else {
    process.env[GATEWAY_TOKEN_ENV] = originalToken;
  }
  await Promise.all([...servers].map(async (server) => server.close()));
  servers.clear();
});

const EXPECTED_ROUTES = [
  { method: 'GET', url: '/' },
  { method: 'GET', url: '/v1/health' },
  { method: 'GET', url: '/v1/projects' },
  { method: 'POST', url: '/v1/tasks' },
  { method: 'GET', url: '/v1/tasks/:taskId' },
  { method: 'GET', url: '/v1/tasks/:taskId/events' },
] as const;

const MUTATING_METHODS = ['POST', 'PUT', 'PATCH', 'DELETE'] as const;

const FORBIDDEN_ROUTE_WORDS = /commit|push|deploy|exec|shell/i;

describe('route surface', () => {
  it('registers exactly the expected routes', async () => {
    const server = buildServer();
    servers.add(server);
    await server.ready();

    for (const route of EXPECTED_ROUTES) {
      expect(
        server.hasRoute({ method: route.method, url: route.url }),
        `expected route ${route.method} ${route.url}`,
      ).toBe(true);
    }

    const routeTree = server.printRoutes({ commonPrefix: false });
    expect(routeTree).not.toMatch(FORBIDDEN_ROUTE_WORDS);
  });

  it('exposes no route that could commit, push, or deploy', async () => {
    const server = buildServer();
    servers.add(server);
    await server.ready();

    const forbiddenUrls = [
      '/v1/commit',
      '/v1/push',
      '/v1/deploy',
      '/v1/git/commit',
      '/v1/git/push',
      '/v1/tasks/some-id/commit',
      '/v1/tasks/some-id/push',
      '/v1/tasks/some-id/deploy',
    ];

    for (const url of forbiddenUrls) {
      for (const method of MUTATING_METHODS) {
        expect(
          server.hasRoute({ method, url }),
          `unexpected route ${method} ${url}`,
        ).toBe(false);
      }

      const response = await server.inject({
        method: 'POST',
        url,
        headers: { authorization: `Bearer ${TEST_TOKEN}` },
        payload: {},
      });
      expect(response.statusCode, `POST ${url} must not exist`).toBe(404);
    }
  });

  it('only registers GET routes besides task creation', async () => {
    const server = buildServer();
    servers.add(server);
    await server.ready();

    for (const route of EXPECTED_ROUTES) {
      if (route.method === 'GET') {
        continue;
      }
      expect(route).toEqual({ method: 'POST', url: '/v1/tasks' });
    }
  });
});

describe('localhost-only posture', () => {
  it('pins the listen host to the loopback interface', () => {
    expect(GATEWAY_HOST).toBe('127.0.0.1');
  });

  it('start() passes the loopback host to Fastify without opening a port', async () => {
    const server = buildServer();
    servers.add(server);
    const listenSpy = vi.spyOn(server, 'listen') as unknown as MockInstance<
      (options: FastifyListenOptions) => Promise<string>
    >;
    listenSpy.mockResolvedValue('http://127.0.0.1:0');

    await start(() => server);

    expect(listenSpy).toHaveBeenCalledTimes(1);
    const [options] = listenSpy.mock.calls[0] ?? [];
    expect(options).toMatchObject({ host: '127.0.0.1' });
    expect(server.addresses()).toHaveLength(0);
  });
});

describe('no external network or shell access in gateway source', () => {
  const srcDir = fileURLToPath(new URL('../src', import.meta.url));

  async function collectSourceFiles(dir: string): Promise<string[]> {
    const entries = await readdir(dir, { withFileTypes: true });
    const files: string[] = [];
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        files.push(...(await collectSourceFiles(fullPath)));
      } else if (entry.name.endsWith('.ts')) {
        files.push(fullPath);
      }
    }
    return files;
  }

  const CHILD_PROCESS_IMPORT = /from\s+['"](?:node:)?child_process['"]/;
  const FORBIDDEN_NETWORK_IMPORT =
    /from\s+['"](?:node:)?(?:net|http|https|dgram|tls)['"]/;
  const PROCESS_SPAWN_CALL = /\bspawn(?:Sync)?\s*\(/;
  const FORBIDDEN_CALLS = [
    /\bfetch\s*\(/,
    /\bexecSync\s*\(/,
    /\bexecFile(?:Sync)?\s*\(/,
    /\brequire\s*\(\s*['"](?:node:)?(?:child_process|net|http|https|dgram|tls)['"]\s*\)/,
  ];

  // The only two modules allowed to start a child process: the Codex
  // app-server transport and the sandboxed test runner. Both spawn a fixed
  // command with shell:false. Adding a third entry is a posture change.
  const SPAWN_ALLOWLIST = new Set([
    path.join('codex', 'transport.ts'),
    'test-runner.ts',
  ]);

  it('imports no networking or process-spawning modules', async () => {
    const files = await collectSourceFiles(srcDir);
    expect(files.length).toBeGreaterThan(0);

    for (const file of files) {
      const source = await readFile(file, 'utf8');
      const relative = path.relative(srcDir, file);
      const maySpawn = SPAWN_ALLOWLIST.has(relative);
      expect(
        FORBIDDEN_NETWORK_IMPORT.test(source),
        `forbidden network import in ${relative}`,
      ).toBe(false);
      expect(
        CHILD_PROCESS_IMPORT.test(source) && !maySpawn,
        `forbidden child-process import in ${relative}`,
      ).toBe(false);
      expect(
        PROCESS_SPAWN_CALL.test(source) && !maySpawn,
        `forbidden spawn call in ${relative}`,
      ).toBe(false);
      for (const pattern of FORBIDDEN_CALLS) {
        expect(
          pattern.test(source),
          `forbidden call ${String(pattern)} in ${relative}`,
        ).toBe(false);
      }
    }
  });
});
