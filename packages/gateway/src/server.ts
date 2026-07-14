import Fastify, { type FastifyInstance } from 'fastify';

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

  server.get('/', async () => ({
    name: '@codex-lens/gateway',
    status: 'ok',
  }));

  return server;
}
