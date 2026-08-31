import Database from 'better-sqlite3';

export type Db = Database.Database;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  display_name TEXT,
  path TEXT,
  allowed_commands JSON,
  allow_workspace_write INTEGER,
  allow_dependency_install INTEGER,
  allow_commit INTEGER,
  allow_push INTEGER,
  allow_deploy INTEGER
);

CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  project_id TEXT,
  state TEXT,
  idempotency_key TEXT UNIQUE,
  created_at TEXT,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS prepared_engineering_plans (
  engineering_plan_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  plan_json TEXT NOT NULL,
  approval_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS prepared_execution_plans (
  execution_plan_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  request_json TEXT NOT NULL,
  plan_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_runs (
  task_id TEXT PRIMARY KEY,
  execution_plan_id TEXT NOT NULL,
  execution_plan_digest TEXT NOT NULL,
  codex_thread_id TEXT,
  follow_up_message TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS message_intents (
  confirmation_id TEXT PRIMARY KEY,
  digest TEXT NOT NULL,
  recipient_display TEXT NOT NULL,
  masked_destination TEXT NOT NULL,
  service_type TEXT NOT NULL CHECK (service_type IN ('iMessage', 'SMS', 'RCS')),
  state TEXT NOT NULL CHECK (state IN ('prepared', 'sending', 'accepted', 'uncertain', 'expired', 'rejected')),
  prepared_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  accepted_at TEXT,
  failure_code TEXT
);

CREATE INDEX IF NOT EXISTS idx_message_intents_state_updated_at
  ON message_intents (state, updated_at);

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  task_id TEXT,
  seq INTEGER,
  type TEXT,
  payload JSON,
  created_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_task_id_seq ON events (task_id, seq);
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_task_id_seq_unique ON events (task_id, seq);
`;

export function openDb(path: string): Db {
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA);
  return db;
}
