import { pathToFileURL } from 'node:url';

import { buildServer } from './server.js';

export { assertExecutionApproved } from './approval-binding.js';

export const GATEWAY_HOST = '127.0.0.1';
const DEFAULT_PORT = 8787;

export async function start(
  createServer: typeof buildServer = buildServer,
): Promise<void> {
  const server = createServer();
  const port = Number.parseInt(
    process.env.CODEX_LENS_PORT ?? `${DEFAULT_PORT}`,
    10,
  );

  await server.listen({
    host: GATEWAY_HOST,
    port,
  });
  server.log.info({ host: GATEWAY_HOST, port }, 'Codex Lens gateway started');
}

const entrypoint = process.argv[1];
if (
  entrypoint !== undefined &&
  import.meta.url === pathToFileURL(entrypoint).href
) {
  await start();
}

export { buildServer } from './server.js';
export {
  RegistryRecordSchema,
  assertCommandAllowed,
  canonicalizePath,
  getProjectById,
  isInsideRootLexically,
  isWithinRoot,
  loadRegistry,
  parseRegistryRecord,
  projectRegistryRecordSchema,
  resolveWorkingDir,
  seedRegistry,
} from './registry/index.js';
export type { RegistryRecord, RegistryRecordInput } from './registry/index.js';
export { assertEditableTarget, resolveRepo } from './registry.js';
export type { RegisteredRepo } from './registry.js';
export {
  CODEX_LENS_REPO_ID,
  CODEX_LENS_REPO_ROOT,
  REPO_REGISTRY,
  SAMPLE_REPO_ID,
  SAMPLE_REPO_ROOT,
} from './registryConfig.js';
export type { RepoRegistryEntry } from './registryConfig.js';
export {
  AppendEventSchema,
  CODEX_LENS_EVENT_TYPES,
  CodexLensEventSchema,
  appendEvent,
  listEvents,
  listEventsAfter,
  parseCodexLensEvent,
} from './events/index.js';
export type { AppendEventInput, CodexLensEvent } from './events/index.js';
export {
  CreateTaskSchema,
  TASK_STATES,
  TaskSchema,
  createTask,
  getTaskById,
  parseCreateTaskInput,
  parseTask,
  transitionTask,
} from './tasks/index.js';
export type { CreateTaskInput, Task, TaskState } from './tasks/index.js';
export { runMockTask } from './runner/index.js';
export type { MockRunOptions, MockRunResult } from './runner/index.js';
export {
  SAMPLE_REPO_TEST_COMMAND,
  generateExecutionPlan,
} from './plan-generation.js';
export type { ExecutionPlanRequest } from './plan-generation.js';
export { runTests } from './test-runner.js';
export type { Sandbox, TestCounts, TestRun } from './test-runner.js';
export {
  readSandboxCleanupFailure,
  runVerticalSlice,
  SANDBOX_CLEANUP_FAILED,
} from './orchestrator.js';
export type {
  ExecutionApproval,
  ExecutionApprovalIssuer,
  SandboxCleanupFailure,
  VerticalSliceOptions,
  VerticalSliceReport,
} from './orchestrator.js';
export {
  CODEX_AUTH_UNAVAILABLE,
  createThread,
  initialize,
  isAuthUnavailable,
  resumeThread,
} from './codex/client.js';
export type {
  CodexClientOptions,
  CodexCreateThreadOptions,
  CodexInitializeOptions,
  CodexInitializeResult,
  CodexThread,
} from './codex/client.js';
export { applyEdit } from './codex/apply-edit.js';
export type { AppliedEdit } from './codex/apply-edit.js';
export { startAppServer } from './codex/transport.js';
export type {
  AppServerHandle,
  AppServerMessage,
  AppServerMessageListener,
  StartAppServerOptions,
} from './codex/transport.js';
export { HealthRequestSchema, HealthResponseSchema } from './routes/health.js';
export type { HealthResponse } from './routes/health.js';
export {
  PROJECTS_PATH,
  ProjectsRequestSchema,
  ProjectsResponseSchema,
} from './routes/projects.js';
export type { ProjectsResponse } from './routes/projects.js';
export {
  CreateTaskRequestSchema,
  TASKS_PATH,
  TaskEventsQuerySchema,
  TaskEventsResponseSchema,
  TaskParamsSchema,
  TaskResponseSchema,
} from './routes/tasks.js';
export type {
  CreateTaskRequest,
  TaskEventsQuery,
  TaskEventsResponse,
} from './routes/tasks.js';
export {
  DEFAULT_REALTIME_MODEL,
  OPENAI_API_KEY_ENV,
  REALTIME_CREDENTIALS_PATH,
  RealtimeCredentialRequestSchema,
  RealtimeCredentialSchema,
  createOpenAiRealtimeIssuer,
  realtimeIssuerFromEnv,
} from './realtime/credentials.js';
export type {
  OpenAiRealtimeIssuerOptions,
  RealtimeCredential,
  RealtimeCredentialIssuer,
  RealtimeCredentialRequest,
} from './realtime/credentials.js';
export { registerRealtimeRoute } from './routes/realtime.js';
