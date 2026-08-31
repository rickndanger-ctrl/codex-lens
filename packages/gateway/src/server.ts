import Fastify, { type FastifyInstance } from 'fastify';

import { registerAuth } from './auth/index.js';
import { openDb, type Db } from './db/schema.js';
import {
  realtimeIssuerFromEnv,
  type RealtimeCredentialIssuer,
} from './realtime/credentials.js';
import { registerHealthRoute } from './routes/health.js';
import { registerProjectsRoute } from './routes/projects.js';
import { registerRealtimeRoute } from './routes/realtime.js';
import { registerTasksRoutes } from './routes/tasks.js';
import { registerEngineeringPlanRoutes } from './routes/engineering-plans.js';
import { registerExecutionPlanRoutes } from './routes/execution-plans.js';
import type { TaskRunner } from './routes/tasks.js';
import { registerComputerRoutes } from './routes/computer.js';
import type {
  ComputerAppFocuser,
  ComputerController,
  ComputerInspector,
  ComputerWindowCloser,
  FrontmostComputerAppReader,
} from './computer/codexComputer.js';
import { registerMessageRoutes } from './routes/messages.js';
import { createMessageService, type MessageService } from './messages/messages.js';
import { registerCodexRoutes, type CodexProjectInspector } from './routes/codex.js';
import { registerWebRoutes } from './routes/web.js';
import { webResearcherFromEnv, type WebResearcher } from './web/research.js';

export const GATEWAY_VERSION = '0.0.0';

export interface BuildServerOptions {
  db?: Db;
  dbPath?: string;
  version?: string;
  /**
   * Mints short-lived OpenAI Realtime credentials. Injected for tests;
   * otherwise built from OPENAI_API_KEY, and absent (route fails closed with
   * 503) when no key is configured.
   */
  realtimeCredentialIssuer?: RealtimeCredentialIssuer;
  /** Performs one policy-bounded, read-only Mac app inspection. */
  computerInspector?: ComputerInspector;
  /** Reads only the active Mac app name without starting a model. */
  frontmostComputerAppReader?: FrontmostComputerAppReader;
  /** Opens or activates one named Mac app through the deterministic fast path. */
  computerAppFocuser?: ComputerAppFocuser;
  /** Closes only the current main window and never resolves save dialogs. */
  computerWindowCloser?: ComputerWindowCloser;
  /** Operates Mac apps and Chrome for an explicit user-directed task. */
  computerController?: ComputerController;
  /** Resolves, prepares, and confirmation-gates Messages sends. */
  messageService?: MessageService;
  /** Runs an approved task. Injectable so route tests never start Codex. */
  taskRunner?: TaskRunner;
  /** Performs a direct, read-only Codex inspection of an allowlisted project. */
  codexProjectInspector?: CodexProjectInspector;
  /** Answers current-information questions using OpenAI's read-only web search. */
  webResearcher?: WebResearcher;
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
  'recipient',
  'message',
  'confirmationId',
  'digest',
  '*.recipient',
  '*.message',
  '*.confirmationId',
  '*.digest',
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

  const db = options.db ?? openDb(options.dbPath ?? ':memory:');
  if (options.db === undefined) {
    server.addHook('onClose', async () => {
      db.close();
    });
  }

  registerAuth(server);
  registerHealthRoute(server, options.version ?? GATEWAY_VERSION);
  registerProjectsRoute(server, db);
  registerEngineeringPlanRoutes(server, db);
  registerExecutionPlanRoutes(server, db);
  registerTasksRoutes(server, db, options.taskRunner);
  registerCodexRoutes(server, db, options.codexProjectInspector);
  registerRealtimeRoute(
    server,
    options.realtimeCredentialIssuer ?? realtimeIssuerFromEnv(),
  );
  registerWebRoutes(server, options.webResearcher ?? webResearcherFromEnv());
  registerComputerRoutes(
    server,
    options.computerInspector,
    options.computerController,
    undefined,
    options.frontmostComputerAppReader,
    options.computerAppFocuser,
    options.computerWindowCloser,
  );
  registerMessageRoutes(
    server,
    options.messageService ?? createMessageService({ db }),
  );

  server.get('/', async () => ({
    name: '@codex-lens/gateway',
    status: 'ok',
  }));

  return server;
}
