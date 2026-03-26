DROP INDEX IF EXISTS idx_workout_summary_jobs_install_session_fingerprint;

CREATE INDEX IF NOT EXISTS idx_workout_summary_jobs_install_session_fingerprint_created_at
ON coach_workout_summary_jobs (install_id, session_id, fingerprint, created_at DESC);
