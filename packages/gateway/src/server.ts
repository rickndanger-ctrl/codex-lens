import Fastify, { type FastifyInstance } from 'fastify';

import { HEALTH_PATH, registerAuth } from './auth/index.js';

const REDACTED_LOG_FIELDS = [
  'authorization',
  'token',
  'credential',
  'apiKey',
  'req.headers.authorization',
  '*.authorization',
  '*.token',
  '*.credential',
  '*.apiKey',
];

export function buildServer(): FastifyInstance {
  const server = Fastify({
    logger: {
      redact: {
        paths: REDACTED_LOG_FIELDS,
        censor: '[REDACTED]',
      },
      serializers: {
        req(request) {
          return {
            method: request.method,
            url: request.url,
            hostname: request.hostname,
            remoteAddress: request.ip,
          };
        },
        res(response) {
          return {
            statusCode: response.statusCode,
          };
        },
      },
    },
  });

  registerAuth(server);

  server.get(HEALTH_PATH, async () => ({
    status: 'ok',
  }));

  server.get('/', async () => ({
    name: '@codex-lens/gateway',
    status: 'ok',
  }));

  return server;
}
