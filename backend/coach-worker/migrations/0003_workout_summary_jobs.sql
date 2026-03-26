CREATE TABLE IF NOT EXISTS coach_workout_summary_jobs (
  job_id TEXT PRIMARY KEY NOT NULL,
  install_id TEXT NOT NULL,
  client_request_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  status TEXT NOT NULL,
  prepared_request_json TEXT NOT NULL,
  response_json TEXT,
  error_code TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  request_mode TEXT NOT NULL,
  trigger TEXT NOT NULL,
  input_mode TEXT NOT NULL,
  current_exercise_count INTEGER NOT NULL DEFAULT 0,
  history_exercise_count INTEGER NOT NULL DEFAULT 0,
  history_session_count INTEGER NOT NULL DEFAULT 0,
  prompt_version TEXT NOT NULL,
  model TEXT NOT NULL,
  prompt_bytes INTEGER,
  fallback_prompt_bytes INTEGER,
  model_duration_ms INTEGER,
  fallback_model_duration_ms INTEGER,
  total_job_duration_ms INTEGER,
  inference_mode TEXT,
  generation_status TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workout_summary_jobs_install_client_request
ON coach_workout_summary_jobs (install_id, client_request_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workout_summary_jobs_install_session_fingerprint
ON coach_workout_summary_jobs (install_id, session_id, fingerprint);

CREATE INDEX IF NOT EXISTS idx_workout_summary_jobs_install_session_created_at
ON coach_workout_summary_jobs (install_id, session_id, created_at DESC);
