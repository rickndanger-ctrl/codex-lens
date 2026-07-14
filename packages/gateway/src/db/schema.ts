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

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  task_id TEXT,
  seq INTEGER,
  type TEXT,
  payload JSON,
  created_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_task_id_seq ON events (task_id, seq);
`;

export function openDb(path: string): Db {
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA);
  return db;
}
