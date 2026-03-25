CREATE TABLE IF NOT EXISTS install_state (
  install_id TEXT PRIMARY KEY NOT NULL,
  current_backup_version INTEGER,
  current_backup_hash TEXT,
  current_backup_r2_key TEXT,
  current_backup_schema_version INTEGER,
  compression TEXT NOT NULL DEFAULT 'gzip',
  size_bytes INTEGER NOT NULL DEFAULT 0,
  uploaded_at TEXT,
  client_source_modified_at TEXT,
  coach_state_version INTEGER NOT NULL DEFAULT 0,
  selected_program_id TEXT,
  program_comment TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS backup_versions (
  install_id TEXT NOT NULL,
  backup_version INTEGER NOT NULL,
  backup_hash TEXT NOT NULL,
  r2_key TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  compression TEXT NOT NULL DEFAULT 'gzip',
  size_bytes INTEGER NOT NULL DEFAULT 0,
  uploaded_at TEXT NOT NULL,
  client_source_modified_at TEXT,
  app_version TEXT NOT NULL,
  build_number TEXT NOT NULL,
  PRIMARY KEY (install_id, backup_version)
);

CREATE TABLE IF NOT EXISTS legacy_compact_snapshots (
  install_id TEXT PRIMARY KEY NOT NULL,
  snapshot_hash TEXT NOT NULL,
  snapshot_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_backup_versions_install_uploaded_at
ON backup_versions (install_id, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_backup_versions_install_hash
ON backup_versions (install_id, backup_hash);
