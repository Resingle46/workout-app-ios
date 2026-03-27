ALTER TABLE coach_chat_jobs ADD COLUMN provider TEXT NOT NULL DEFAULT 'workers_ai';
ALTER TABLE coach_workout_summary_jobs ADD COLUMN provider TEXT NOT NULL DEFAULT 'workers_ai';

DROP INDEX IF EXISTS coach_chat_jobs_install_client_request_idx;
CREATE UNIQUE INDEX IF NOT EXISTS coach_chat_jobs_install_client_request_provider_idx
  ON coach_chat_jobs(install_id, client_request_id, provider);

DROP INDEX IF EXISTS coach_workout_summary_jobs_install_client_request_idx;
CREATE UNIQUE INDEX IF NOT EXISTS coach_workout_summary_jobs_install_client_request_provider_idx
  ON coach_workout_summary_jobs(install_id, client_request_id, provider);

DROP INDEX IF EXISTS coach_workout_summary_jobs_install_session_fingerprint_idx;
CREATE INDEX IF NOT EXISTS coach_workout_summary_jobs_install_session_fingerprint_provider_idx
  ON coach_workout_summary_jobs(install_id, session_id, fingerprint, provider, created_at DESC);
