import type { Db } from '../db/schema.js';

export const MESSAGE_INTENT_STATES = [
  'prepared',
  'sending',
  'accepted',
  'uncertain',
  'expired',
  'rejected',
] as const;

export type MessageIntentState = typeof MESSAGE_INTENT_STATES[number];

export interface MessageIntentRecord {
  confirmationId: string;
  digest: string;
  recipientDisplay: string;
  maskedDestination: string;
  serviceType: 'iMessage' | 'SMS' | 'RCS';
  state: MessageIntentState;
  preparedAt: string;
  expiresAt: string;
  updatedAt: string;
  acceptedAt?: string;
  failureCode?: string;
}

export interface MessageIntentStore {
  insert(record: MessageIntentRecord): void;
  get(confirmationId: string): MessageIntentRecord | undefined;
  transition(
    confirmationId: string,
    expected: readonly MessageIntentState[],
    next: MessageIntentState,
    updatedAt: string,
    details?: { acceptedAt?: string; failureCode?: string },
  ): boolean;
}

function clone(record: MessageIntentRecord): MessageIntentRecord {
  return { ...record };
}

export function createMemoryMessageIntentStore(): MessageIntentStore {
  const records = new Map<string, MessageIntentRecord>();
  return {
    insert(record) {
      if (records.has(record.confirmationId)) {
        throw new Error(`Duplicate message confirmation id: ${record.confirmationId}`);
      }
      records.set(record.confirmationId, clone(record));
    },
    get(confirmationId) {
      const record = records.get(confirmationId);
      return record === undefined ? undefined : clone(record);
    },
    transition(confirmationId, expected, next, updatedAt, details = {}) {
      const record = records.get(confirmationId);
      if (record === undefined || !expected.includes(record.state)) return false;
      records.set(confirmationId, {
        ...record,
        state: next,
        updatedAt,
        ...(details.acceptedAt === undefined ? {} : { acceptedAt: details.acceptedAt }),
        ...(details.failureCode === undefined ? {} : { failureCode: details.failureCode }),
      });
      return true;
    },
  };
}

interface MessageIntentRow {
  confirmation_id: string;
  digest: string;
  recipient_display: string;
  masked_destination: string;
  service_type: MessageIntentRecord['serviceType'];
  state: MessageIntentState;
  prepared_at: string;
  expires_at: string;
  updated_at: string;
  accepted_at: string | null;
  failure_code: string | null;
}

function fromRow(row: MessageIntentRow): MessageIntentRecord {
  return {
    confirmationId: row.confirmation_id,
    digest: row.digest,
    recipientDisplay: row.recipient_display,
    maskedDestination: row.masked_destination,
    serviceType: row.service_type,
    state: row.state,
    preparedAt: row.prepared_at,
    expiresAt: row.expires_at,
    updatedAt: row.updated_at,
    ...(row.accepted_at === null ? {} : { acceptedAt: row.accepted_at }),
    ...(row.failure_code === null ? {} : { failureCode: row.failure_code }),
  };
}

export function createSqliteMessageIntentStore(db: Db): MessageIntentStore {
  const insert = db.prepare(`
    INSERT INTO message_intents (
      confirmation_id,
      digest,
      recipient_display,
      masked_destination,
      service_type,
      state,
      prepared_at,
      expires_at,
      updated_at,
      accepted_at,
      failure_code
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const get = db.prepare(`
    SELECT
      confirmation_id,
      digest,
      recipient_display,
      masked_destination,
      service_type,
      state,
      prepared_at,
      expires_at,
      updated_at,
      accepted_at,
      failure_code
    FROM message_intents
    WHERE confirmation_id = ?
  `);

  return {
    insert(record) {
      insert.run(
        record.confirmationId,
        record.digest,
        record.recipientDisplay,
        record.maskedDestination,
        record.serviceType,
        record.state,
        record.preparedAt,
        record.expiresAt,
        record.updatedAt,
        record.acceptedAt ?? null,
        record.failureCode ?? null,
      );
    },
    get(confirmationId) {
      const row = get.get(confirmationId) as MessageIntentRow | undefined;
      return row === undefined ? undefined : fromRow(row);
    },
    transition(confirmationId, expected, next, updatedAt, details = {}) {
      if (expected.length === 0) return false;
      const placeholders = expected.map(() => '?').join(', ');
      const update = db.prepare(`
        UPDATE message_intents
        SET state = ?, updated_at = ?, accepted_at = ?, failure_code = ?
        WHERE confirmation_id = ? AND state IN (${placeholders})
      `);
      const result = update.run(
        next,
        updatedAt,
        details.acceptedAt ?? null,
        details.failureCode ?? null,
        confirmationId,
        ...expected,
      );
      return result.changes === 1;
    },
  };
}
