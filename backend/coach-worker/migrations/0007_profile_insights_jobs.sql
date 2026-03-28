CREATE TABLE IF NOT EXISTS coach_profile_insights_jobs (
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
  snapshot_bytes INTEGER NOT NULL DEFAULT 0,
  program_comment_chars INTEGER NOT NULL DEFAULT 0,
  recent_pr_count INTEGER NOT NULL DEFAULT 0,
  relative_strength_count INTEGER NOT NULL DEFAULT 0,
  preferred_program_workout_count INTEGER NOT NULL DEFAULT 0,
  prompt_version TEXT NOT NULL,
  model TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT 'workers_ai',
  prompt_bytes INTEGER,
  fallback_prompt_bytes INTEGER,
  model_duration_ms INTEGER,
  fallback_model_duration_ms INTEGER,
  total_job_duration_ms INTEGER,
  inference_mode TEXT,
  generation_status TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_profile_insights_jobs_install_client_request_provider
ON coach_profile_insights_jobs (install_id, client_request_id, provider);

CREATE INDEX IF NOT EXISTS idx_profile_insights_jobs_install_created_at
ON coach_profile_insights_jobs (install_id, created_at DESC);
