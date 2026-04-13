-- ─────────────────────────────────────────────────────────────────────────────
-- 01_schema.sql
-- Creates the TimescaleDB extension and the `measurements` hypertable used
-- for BioT CSV exports. Runs once, automatically, on first container boot
-- (Postgres executes every file in /docker-entrypoint-initdb.d in order).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- ── Core hypertable ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS measurements (
    time          TIMESTAMPTZ      NOT NULL,
    pid           TEXT             NOT NULL,   -- patient id
    sid           TEXT             NOT NULL,   -- device / session id
    usid          TEXT             NOT NULL,   -- usage session id
    start_time    TIMESTAMPTZ,                 -- session start time
    measure_name  TEXT             NOT NULL,
    value         DOUBLE PRECISION NOT NULL
);

SELECT create_hypertable(
    'measurements',
    'time',
    if_not_exists       => TRUE,
    chunk_time_interval => INTERVAL '1 day'
);

-- ── Indexes (tuned for Grafana query patterns) ───────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS idx_measurements_unique
    ON measurements (time, pid, sid, usid, measure_name);

CREATE INDEX IF NOT EXISTS idx_measurements_pid_time
    ON measurements (pid, time DESC);

CREATE INDEX IF NOT EXISTS idx_measurements_sid_time
    ON measurements (sid, time DESC);

CREATE INDEX IF NOT EXISTS idx_measurements_measure_time
    ON measurements (measure_name, time DESC);

\echo 'TimescaleDB schema initialised.'
