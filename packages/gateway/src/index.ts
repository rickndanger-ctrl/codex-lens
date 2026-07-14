import { pathToFileURL } from 'node:url';

import { buildServer } from './server.js';

export const GATEWAY_HOST = '127.0.0.1';
const DEFAULT_PORT = 8787;

export async function start(): Promise<void> {
  const server = buildServer();
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
  isWithinRoot,
  loadRegistry,
  parseRegistryRecord,
  projectRegistryRecordSchema,
  resolveWorkingDir,
  seedRegistry,
} from './registry/index.js';
export type { RegistryRecord, RegistryRecordInput } from './registry/index.js';
export {
  AppendEventSchema,
  CODEX_LENS_EVENT_TYPES,
  CodexLensEventSchema,
  appendEvent,
  listEvents,
  parseCodexLensEvent,
} from './events/index.js';
export type { AppendEventInput, CodexLensEvent } from './events/index.js';
export {
  CreateTaskSchema,
  TASK_STATES,
  TaskSchema,
  createTask,
  parseCreateTaskInput,
  parseTask,
  transitionTask,
} from './tasks/index.js';
export type { CreateTaskInput, Task, TaskState } from './tasks/index.js';
export { runMockTask } from './runner/index.js';
export type { MockRunOptions, MockRunResult } from './runner/index.js';
