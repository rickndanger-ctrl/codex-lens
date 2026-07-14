import { randomUUID } from 'node:crypto';

import { err, ok, type Result } from '@codex-lens/shared';

import type { Db } from '../db/schema.js';
import type { CodexLensEvent } from '../events/event.js';
import { appendEvent } from '../events/eventStore.js';
import { assertCommandAllowed } from '../registry/pathSafety.js';
import type { RegistryRecord } from '../registry/projectRegistry.js';
import type { Task } from '../tasks/task.js';
import { transitionTask } from '../tasks/taskStore.js';

export interface MockRunOptions {
  /**
   * Commands the simulated run pretends to execute. Defaults to the
   * project's allowedCommands, which always yields a completing run.
   */
  commands?: readonly string[];
  /** Injectable ISO-8601 timestamp source so tests stay deterministic. */
  clock?: () => string;
}

export interface MockRunResult {
  task: Task;
  events: readonly CodexLensEvent[];
}

// Yields one microtask between lifecycle stages so the runner is genuinely
// asynchronous without depending on real timers.
function nextStage(): Promise<void> {
  return Promise.resolve();
}

export async function runMockTask(
  db: Db,
  task: Task,
  project: RegistryRecord,
  options: MockRunOptions = {},
): Promise<Result<MockRunResult>> {
  if (task.projectId !== project.id) {
    return err(
      'TASK_PROJECT_MISMATCH',
      `Task ${task.id} belongs to project "${task.projectId}", not "${project.id}"`,
    );
  }
  // Check the stored state, not the caller's snapshot, so a task that was
  // already run cannot be started again from a stale Task object.
  const stored = db
    .prepare('SELECT state FROM tasks WHERE id = ?')
    .get(task.id) as { state: string } | undefined;
  if (stored === undefined) {
    return err('TASK_NOT_FOUND', `No task with id ${task.id}`);
  }
  if (stored.state !== 'queued') {
    return err(
      'TASK_NOT_RUNNABLE',
      `Task ${task.id} is in state "${stored.state}"; only queued tasks can be run`,
    );
  }

  const commands = options.commands ?? project.allowedCommands;
  const clock = options.clock ?? (() => new Date().toISOString());
  const events: CodexLensEvent[] = [];

  const emit = (
    type: CodexLensEvent['type'],
    payload: Record<string, unknown>,
  ): Result<CodexLensEvent> => {
    const appended = appendEvent(db, {
      id: randomUUID(),
      taskId: task.id,
      type,
      payload,
      createdAt: clock(),
    });
    if (appended.ok) {
      events.push(appended.value);
    }
    return appended;
  };

  const queuedEvent = emit('queued', { projectId: project.id });
  if (!queuedEvent.ok) {
    return queuedEvent;
  }

  await nextStage();

  const running = transitionTask(db, task.id, 'running');
  if (!running.ok) {
    return running;
  }
  const runningEvent = emit('running', { commands: [...commands] });
  if (!runningEvent.ok) {
    return runningEvent;
  }

  for (const command of commands) {
    await nextStage();

    const allowed = assertCommandAllowed(command, project.allowedCommands);
    if (!allowed.ok) {
      const failedEvent = emit('failed', {
        command,
        code: allowed.error.code,
        message: allowed.error.message,
      });
      if (!failedEvent.ok) {
        return failedEvent;
      }
      const failed = transitionTask(db, task.id, 'failed');
      if (!failed.ok) {
        return failed;
      }
      return ok({ task: failed.value, events });
    }

    const logEvent = emit('log', {
      command,
      stream: 'stdout',
      line: `[mock] ${command}`,
    });
    if (!logEvent.ok) {
      return logEvent;
    }
  }

  await nextStage();

  const completeEvent = emit('complete', {
    exitCode: 0,
    commandCount: commands.length,
  });
  if (!completeEvent.ok) {
    return completeEvent;
  }
  const complete = transitionTask(db, task.id, 'complete');
  if (!complete.ok) {
    return complete;
  }

  return ok({ task: complete.value, events });
}
