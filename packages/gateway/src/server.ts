import Fastify, { type FastifyInstance } from 'fastify';

import { registerAuth } from './auth/index.js';
import { openDb, type Db } from './db/schema.js';
import { registerHealthRoute } from './routes/health.js';
import { registerProjectsRoute } from './routes/projects.js';

export const GATEWAY_VERSION = '0.0.0';

export interface BuildServerOptions {
  db?: Db;
  version?: string;
}

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

export function buildServer(options: BuildServerOptions = {}): FastifyInstance {
  const server = Fastify({
    ajv: {
      customOptions: {
        removeAdditional: false,
      },
    },
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

  const db = options.db ?? openDb(':memory:');
  if (options.db === undefined) {
    server.addHook('onClose', async () => {
      db.close();
    });
  }

  registerAuth(server);
  registerHealthRoute(server, options.version ?? GATEWAY_VERSION);
  registerProjectsRoute(server, db);

  server.get('/', async () => ({
    name: '@codex-lens/gateway',
    status: 'ok',
  }));

  return server;
}
