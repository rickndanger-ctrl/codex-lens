import { afterEach, describe, expect, it } from 'vitest';

import { buildServer } from '../src/server.js';

const servers = new Set<ReturnType<typeof buildServer>>();

afterEach(async () => {
  await Promise.all([...servers].map(async (server) => server.close()));
  servers.clear();
});

describe('buildServer', () => {
  it('returns a Fastify server that responds with 404 for an unknown route', async () => {
    const server = buildServer();
    servers.add(server);

    const response = await server.inject({
      method: 'GET',
      url: '/nonexistent',
    });

    expect(response.statusCode).toBe(404);
  });
});
