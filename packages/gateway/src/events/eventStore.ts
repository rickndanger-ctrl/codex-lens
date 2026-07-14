import { err, type Result } from '@codex-lens/shared';

import type { Db } from '../db/schema.js';
import {
  AppendEventSchema,
  parseCodexLensEvent,
  type AppendEventInput,
  type CodexLensEvent,
} from './event.js';

interface EventRow {
  id: string;
  task_id: string;
  seq: number;
  type: string;
  payload: string;
  created_at: string;
}

const RETURNING_COLUMNS = `
  id,
  task_id,
  seq,
  type,
  payload,
  created_at
`;

function rowToEvent(row: EventRow): Result<CodexLensEvent> {
  let payload: unknown;
  try {
    payload = JSON.parse(row.payload);
  } catch {
    return err('INVALID_STORED_EVENT', `Event ${row.id} has invalid JSON payload`);
  }

  const parsed = parseCodexLensEvent({
    id: row.id,
    taskId: row.task_id,
    seq: row.seq,
    type: row.type,
    payload,
    createdAt: row.created_at,
  });
  if (!parsed.ok) {
    return err('INVALID_STORED_EVENT', parsed.error.message);
  }

  return parsed;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function appendEvent(
  db: Db,
  event: AppendEventInput,
): Result<CodexLensEvent> {
  const parsed = AppendEventSchema.safeParse(event);
  if (!parsed.success) {
    const message = parsed.error.issues
      .map((issue) => `${issue.path.join('.') || '(root)'}: ${issue.message}`)
      .join('; ');
    return err('INVALID_CODEX_LENS_EVENT', message);
  }

  try {
    const row = db
      .prepare(
        `INSERT INTO events (id, task_id, seq, type, payload, created_at)
         SELECT @id, @taskId, COALESCE(MAX(seq), -1) + 1, @type, @payload, @createdAt
         FROM events
         WHERE task_id = @taskId
         RETURNING ${RETURNING_COLUMNS}`,
      )
      .get({
        ...parsed.data,
        payload: JSON.stringify(parsed.data.payload),
      }) as EventRow | undefined;

    if (row === undefined) {
      return err('EVENT_STORE_WRITE_FAILED', 'SQLite did not return the appended event');
    }

    return rowToEvent(row);
  } catch (error) {
    return err('EVENT_STORE_WRITE_FAILED', errorMessage(error));
  }
}

export function listEvents(db: Db, taskId: string): Result<CodexLensEvent[]> {
  if (taskId.trim().length === 0) {
    return err('INVALID_TASK_ID', 'taskId must not be empty');
  }

  try {
    const rows = db
      .prepare(
        `SELECT ${RETURNING_COLUMNS}
         FROM events
         WHERE task_id = ?
         ORDER BY seq ASC`,
      )
      .all(taskId) as EventRow[];

    const events: CodexLensEvent[] = [];
    for (const row of rows) {
      const event = rowToEvent(row);
      if (!event.ok) {
        return event;
      }
      events.push(event.value);
    }

    return { ok: true, value: events };
  } catch (error) {
    return err('EVENT_STORE_READ_FAILED', errorMessage(error));
  }
}
