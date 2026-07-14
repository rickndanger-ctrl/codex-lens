import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { afterEach, describe, expect, it } from 'vitest';

import { openDb, type Db } from '../src/db/schema.js';
import { createTask, transitionTask } from '../src/tasks/taskStore.js';

const dbs = new Set<Db>();
const tempDirs = new Set<string>();

function open(path: string): Db {
  const db = openDb(path);
  dbs.add(db);
  return db;
}

function close(db: Db): void {
  db.close();
  dbs.delete(db);
}

function mustSucceed<T>(result: { ok: true; value: T } | { ok: false }): T {
  expect(result.ok).toBe(true);
  if (!result.ok) {
    throw new Error('Expected successful Result');
  }
  return result.value;
}

function countTasks(db: Db): number {
  const row = db.prepare('SELECT COUNT(*) AS count FROM tasks').get() as {
    count: number;
  };
  return row.count;
}

afterEach(() => {
  for (const db of dbs) {
    db.close();
  }
  dbs.clear();
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.clear();
});

describe('createTask', () => {
  it('creates a queued task with generated id and timestamps', () => {
    const db = open(':memory:');

    const task = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );

    expect(task.id).not.toHaveLength(0);
    expect(task.projectId).toBe('project-1');
    expect(task.state).toBe('queued');
    expect(task.idempotencyKey).toBe('key-1');
    expect(task.createdAt).toBe(task.updatedAt);
    expect(countTasks(db)).toBe(1);
  });

  it('returns the existing task for a duplicate idempotencyKey without adding a row', () => {
    const db = open(':memory:');

    const first = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );
    const second = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );

    expect(second.id).toBe(first.id);
    expect(second).toEqual(first);
    expect(countTasks(db)).toBe(1);
  });

  it('creates distinct tasks for distinct idempotencyKeys', () => {
    const db = open(':memory:');

    const first = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );
    const second = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-2' }),
    );

    expect(second.id).not.toBe(first.id);
    expect(countTasks(db)).toBe(2);
  });

  it('returns a failed Result for invalid input', () => {
    const db = open(':memory:');

    const result = createTask(db, { projectId: '', idempotencyKey: 'key-1' });

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('INVALID_CREATE_TASK_INPUT');
    }
  });
});

describe('transitionTask', () => {
  it('walks the full lifecycle queued -> running -> complete', () => {
    const db = open(':memory:');
    const task = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );

    const running = mustSucceed(transitionTask(db, task.id, 'running'));
    expect(running.state).toBe('running');

    const complete = mustSucceed(transitionTask(db, task.id, 'complete'));
    expect(complete.state).toBe('complete');
  });

  it('allows running -> failed', () => {
    const db = open(':memory:');
    const task = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );

    mustSucceed(transitionTask(db, task.id, 'running'));
    const failed = mustSucceed(transitionTask(db, task.id, 'failed'));
    expect(failed.state).toBe('failed');
  });

  it('rejects the illegal skip transition queued -> complete', () => {
    const db = open(':memory:');
    const task = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );

    const result = transitionTask(db, task.id, 'complete');

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('INVALID_TASK_TRANSITION');
    }
  });

  it('rejects transitions out of a terminal state', () => {
    const db = open(':memory:');
    const task = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );
    mustSucceed(transitionTask(db, task.id, 'running'));
    mustSucceed(transitionTask(db, task.id, 'complete'));

    const result = transitionTask(db, task.id, 'failed');

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('INVALID_TASK_TRANSITION');
    }
  });

  it('treats re-applying the current state as a no-op success', () => {
    const db = open(':memory:');
    const task = mustSucceed(
      createTask(db, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );
    const running = mustSucceed(transitionTask(db, task.id, 'running'));

    const again = mustSucceed(transitionTask(db, task.id, 'running'));

    expect(again).toEqual(running);
    expect(countTasks(db)).toBe(1);
  });

  it('returns a failed Result for an unknown task id', () => {
    const db = open(':memory:');

    const result = transitionTask(db, 'missing-task', 'running');

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('TASK_NOT_FOUND');
    }
  });

  it('persists state changes across database reopen', () => {
    const dir = mkdtempSync(join(tmpdir(), 'gateway-task-store-test-'));
    tempDirs.add(dir);
    const path = join(dir, 'gateway.sqlite');

    const firstDb = open(path);
    const task = mustSucceed(
      createTask(firstDb, { projectId: 'project-1', idempotencyKey: 'key-1' }),
    );
    mustSucceed(transitionTask(firstDb, task.id, 'running'));
    close(firstDb);

    const reopenedDb = open(path);
    const reapplied = mustSucceed(transitionTask(reopenedDb, task.id, 'running'));
    expect(reapplied.state).toBe('running');

    const complete = mustSucceed(transitionTask(reopenedDb, task.id, 'complete'));
    expect(complete.state).toBe('complete');
    expect(complete.id).toBe(task.id);
  });
});
