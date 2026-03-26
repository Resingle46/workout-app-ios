CREATE TABLE IF NOT EXISTS coach_chat_jobs (
  job_id TEXT PRIMARY KEY NOT NULL,
  install_id TEXT NOT NULL,
  client_request_id TEXT NOT NULL,
  status TEXT NOT NULL,
  prepared_request_json TEXT NOT NULL,
  response_json TEXT,
  error_code TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  context_hash TEXT NOT NULL,
  context_source TEXT NOT NULL,
  chat_memory_hit INTEGER NOT NULL DEFAULT 0,
  snapshot_bytes INTEGER NOT NULL DEFAULT 0,
  recent_turn_count INTEGER NOT NULL DEFAULT 0,
  recent_turn_chars INTEGER NOT NULL DEFAULT 0,
  question_chars INTEGER NOT NULL DEFAULT 0,
  prompt_version TEXT NOT NULL,
  model TEXT NOT NULL,
  prompt_bytes INTEGER,
  fallback_prompt_bytes INTEGER,
  model_duration_ms INTEGER,
  fallback_model_duration_ms INTEGER,
  total_job_duration_ms INTEGER,
  inference_mode TEXT,
  generation_status TEXT,
  memory_committed_at TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_coach_chat_jobs_install_client_request
ON coach_chat_jobs (install_id, client_request_id);

CREATE INDEX IF NOT EXISTS idx_coach_chat_jobs_install_created_at
ON coach_chat_jobs (install_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_coach_chat_jobs_install_active
ON coach_chat_jobs (install_id)
WHERE status IN ('queued', 'running');
