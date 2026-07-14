import { randomUUID } from 'node:crypto';

import { err, ok, type Result } from '@codex-lens/shared';

import type { Db } from '../db/schema.js';
import type { CodexLensEvent } from '../events/event.js';
import { appendEvent } from '../events/eventStore.js';
import { assertCommandAllowed } from '../registry/pathSafety.js';
import type { RegistryRecord } from '../registry/projectRegistry.js';
import type { Task } from '../tasks/task.js';
import { claimQueuedTask, transitionTask } from '../tasks/taskStore.js';

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
  // Atomically claim the task (queued -> running) before emitting anything:
  // of any number of concurrent runners exactly one wins the conditional
  // update, so only one executes and appends lifecycle events. The claim
  // checks the stored row's project_id, not just the caller's snapshot.
  const claimed = claimQueuedTask(db, task.id, project.id);
  if (!claimed.ok) {
    return claimed;
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
