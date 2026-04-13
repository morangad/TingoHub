#!/usr/bin/env bash
# =============================================================================
# TimescaleDB Optimization Script — biot_measurements (440M rows)
# =============================================================================
# Run this from the same directory as your docker-compose.yml.
# It connects to the running TimescaleDB container and applies all
# optimizations in the correct, safe order.
#
# Usage:
#   chmod +x optimize_timescaledb.sh
#   ./optimize_timescaledb.sh
#
# To skip interactive prompts (e.g. in CI): ./optimize_timescaledb.sh --yes
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

DB_USER="${DB_USER:-tsdbadmin}"
DB_NAME="${DB_NAME:-metrics}"
DB_PASSWORD="${DB_PASSWORD:-}"
CONTAINER_NAME="timescaledb"          # docker-compose service name
TABLE="biot_measurements"
CAGG="biot_hourly"

AUTO_YES=false
[[ "${1:-}" == "--yes" ]] && AUTO_YES=true

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

confirm() {
  if $AUTO_YES; then return 0; fi
  echo -e "${YELLOW}$* [y/N]${RESET} \c"
  read -r ans
  [[ "${ans,,}" == "y" ]]
}

# Run SQL and print output
psql() {
  docker exec -i "$CONTAINER_NAME" \
    env PGPASSWORD="$DB_PASSWORD" \
    psql -U "$DB_USER" -d "$DB_NAME" \
    --no-password -X -A -t "$@"
}

# Run SQL, show pretty output
psql_pretty() {
  docker exec -i "$CONTAINER_NAME" \
    env PGPASSWORD="$DB_PASSWORD" \
    psql -U "$DB_USER" -d "$DB_NAME" \
    --no-password -X "$@"
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
section "Pre-flight checks"

docker info &>/dev/null || die "Docker is not running."
docker exec "$CONTAINER_NAME" echo "ok" &>/dev/null \
  || die "Container '$CONTAINER_NAME' is not reachable. Start it with: docker compose up -d"

ok "Docker container is running."

TS_VERSION=$(psql -c "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';")
[[ -n "$TS_VERSION" ]] || die "TimescaleDB extension not found in database '$DB_NAME'."
ok "TimescaleDB version: $TS_VERSION"

ROW_EST=$(psql -c "SELECT approximate_row_count('$TABLE');")
log "Approximate row count: $(printf '%d' "$ROW_EST" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"

# ── Step 1: VACUUM ANALYZE ────────────────────────────────────────────────────
section "Step 1 — VACUUM ANALYZE (refresh statistics)"
log "This updates planner statistics and reclaims dead tuples from bulk load."
log "Duration: a few minutes on 440M rows — you can continue to the next step in another terminal."

if confirm "Run VACUUM ANALYZE on $TABLE now?"; then
  psql_pretty << SQL
    VACUUM (ANALYZE, VERBOSE) $TABLE;
SQL
  ok "VACUUM ANALYZE complete."
else
  warn "Skipped. Run manually: VACUUM (ANALYZE, VERBOSE) $TABLE;"
fi

# ── Step 2: Compression ───────────────────────────────────────────────────────
section "Step 2 — Enable chunk compression"

COMPRESSION_ENABLED=$(psql -c "
  SELECT compression_enabled
  FROM timescaledb_information.hypertables
  WHERE hypertable_name = '$TABLE';
")

if [[ "$COMPRESSION_ENABLED" == "t" ]]; then
  ok "Compression already enabled on $TABLE."
else
  log "Enabling compression (segmentby: pid, sid, measure_name | orderby: time DESC)..."
  if confirm "Apply compression settings to $TABLE?"; then
    psql_pretty << SQL
      ALTER TABLE $TABLE SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'pid, sid, measure_name',
        timescaledb.compress_orderby   = 'time DESC'
      );
SQL
    ok "Compression settings applied."
  fi
fi

# Add compression policy (auto-compress chunks older than 7 days)
COMPRESS_POLICY=$(psql -c "
  SELECT count(*) FROM timescaledb_information.jobs
  WHERE hypertable_name = '$TABLE'
    AND proc_name = 'policy_compression';
")

if [[ "$COMPRESS_POLICY" -gt 0 ]]; then
  ok "Compression policy already exists."
else
  if confirm "Add auto-compression policy (compress chunks older than 7 days)?"; then
    psql_pretty << SQL
      SELECT add_compression_policy('$TABLE', INTERVAL '7 days');
SQL
    ok "Compression policy added."
  fi
fi

# Compress existing chunks in batches (safe, incremental)
section "Step 2b — Compress existing chunks (incremental)"
log "Compressing chunks in batches of 10, oldest first."
log "Each batch of 10 chunks typically takes 1–5 minutes. Safe to Ctrl+C and resume later."
warn "Run this during off-peak hours — it uses significant I/O."

UNCOMPRESSED=$(psql -c "
  SELECT count(*) FROM timescaledb_information.chunks
  WHERE hypertable_name = '$TABLE'
    AND is_compressed = false
    AND range_end < NOW() - INTERVAL '7 days';
")
log "Uncompressed chunks eligible for compression: $UNCOMPRESSED"

if [[ "$UNCOMPRESSED" -gt 0 ]] && confirm "Compress existing chunks now?"; then
  psql_pretty << 'SQL'
DO $$
DECLARE
  chunk_rec RECORD;
  compressed INT := 0;
  skipped    INT := 0;
  batch_size INT := 10;
  counter    INT := 0;
BEGIN
  FOR chunk_rec IN
    SELECT chunk_schema, chunk_name
    FROM timescaledb_information.chunks
    WHERE hypertable_name = 'biot_measurements'
      AND is_compressed    = false
      AND range_end        < NOW() - INTERVAL '7 days'
    ORDER BY range_start ASC
  LOOP
    BEGIN
      PERFORM compress_chunk(
        format('%I.%I', chunk_rec.chunk_schema, chunk_rec.chunk_name)
      );
      compressed := compressed + 1;
      counter    := counter    + 1;
      RAISE NOTICE 'Compressed chunk % (% total)', chunk_rec.chunk_name, compressed;

      -- Commit every batch_size chunks so progress is not lost on interruption
      IF counter >= batch_size THEN
        counter := 0;
        RAISE NOTICE '--- batch checkpoint ---';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      skipped := skipped + 1;
      RAISE WARNING 'Skipped chunk %: %', chunk_rec.chunk_name, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Done. Compressed: %, Skipped: %', compressed, skipped;
END;
$$;
SQL
  ok "Chunk compression pass complete."
fi

# ── Step 3: Chunk interval ────────────────────────────────────────────────────
section "Step 3 — Set chunk interval to 7 days (new chunks only)"
log "Current interval is 1 day. Changing to 7 days reduces chunk count overhead."
log "Existing chunks are NOT rewritten — only future chunks use the new interval."

CURRENT_INTERVAL=$(psql -c "
  SELECT time_interval
  FROM timescaledb_information.dimensions
  WHERE hypertable_name = '$TABLE';
")
log "Current chunk interval: $CURRENT_INTERVAL"

if confirm "Change chunk interval to 7 days?"; then
  psql_pretty << SQL
    SELECT set_chunk_time_interval('$TABLE', INTERVAL '7 days');
SQL
  ok "Chunk interval updated to 7 days."
fi

# ── Step 4: Continuous aggregate backfill ─────────────────────────────────────
section "Step 4 — Populate continuous aggregate ($CAGG)"
log "Checking if $CAGG exists and is empty..."

CAGG_EXISTS=$(psql -c "
  SELECT count(*) FROM timescaledb_information.continuous_aggregates
  WHERE view_name = '$CAGG';
")

if [[ "$CAGG_EXISTS" -eq 0 ]]; then
  warn "$CAGG does not exist — skipping. Check your init scripts."
else
  CAGG_ROWS=$(psql -c "SELECT count(*) FROM $CAGG;")
  log "$CAGG current row count: $CAGG_ROWS"

  if [[ "$CAGG_ROWS" -eq 0 ]]; then
    warn "$CAGG is empty (was created WITH NO DATA). A full backfill on 440M rows may take hours."
    warn "Recommended: run this overnight, or in a tmux/screen session."
    if confirm "Start backfill now? (blocks this terminal until complete)"; then
      psql_pretty << SQL
        CALL refresh_continuous_aggregate('$CAGG', NULL, NOW());
SQL
      ok "Backfill complete."
    else
      log "To run the backfill manually (e.g. in a screen session):"
      echo "  docker exec -it $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME \\"
      echo "    -c \"CALL refresh_continuous_aggregate('$CAGG', NULL, NOW());\""
    fi
  else
    ok "$CAGG is already populated ($CAGG_ROWS rows)."
  fi

  # Ensure a refresh policy exists
  CAGG_POLICY=$(psql -c "
    SELECT count(*) FROM timescaledb_information.jobs
    WHERE hypertable_name = '$CAGG'
      AND proc_name = 'policy_refresh_continuous_aggregate';
  ")
  if [[ "$CAGG_POLICY" -eq 0 ]]; then
    if confirm "Add refresh policy to $CAGG (refresh last 3 hours, every hour)?"; then
      psql_pretty << SQL
        SELECT add_continuous_aggregate_policy('$CAGG',
          start_offset      => INTERVAL '3 hours',
          end_offset        => INTERVAL '1 hour',
          schedule_interval => INTERVAL '1 hour'
        );
SQL
      ok "Refresh policy added."
    fi
  else
    ok "Refresh policy already exists on $CAGG."
  fi
fi

# ── Step 5: Retention policy ──────────────────────────────────────────────────
section "Step 5 — Retention policy on $TABLE"
log "Drops raw chunks older than 180 days. Make sure $CAGG is fully backfilled first!"

RETENTION_EXISTS=$(psql -c "
  SELECT count(*) FROM timescaledb_information.jobs
  WHERE hypertable_name = '$TABLE'
    AND proc_name = 'policy_retention';
")

if [[ "$RETENTION_EXISTS" -gt 0 ]]; then
  ok "Retention policy already exists on $TABLE."
else
  warn "This will permanently delete raw rows older than 180 days."
  warn "Only proceed if $CAGG is fully backfilled."
  if confirm "Add 180-day retention policy to $TABLE?"; then
    psql_pretty << SQL
      SELECT add_retention_policy('$TABLE', INTERVAL '180 days');
SQL
    ok "Retention policy added."
  else
    log "Skipped. To add later:"
    echo "  SELECT add_retention_policy('$TABLE', INTERVAL '180 days');"
  fi
fi

# ── Step 6: Verify everything ─────────────────────────────────────────────────
section "Final status check"

psql_pretty << SQL
-- Hypertable summary
SELECT
  h.hypertable_name,
  h.compression_enabled,
  d.time_interval                      AS chunk_interval,
  approximate_row_count(h.hypertable_name::regclass) AS approx_rows
FROM timescaledb_information.hypertables h
JOIN timescaledb_information.dimensions d USING (hypertable_name)
WHERE h.hypertable_name = '$TABLE';

-- Chunk compression breakdown
SELECT
  is_compressed,
  count(*)          AS chunks,
  pg_size_pretty(sum(before_compression_total_bytes))  AS size_before,
  pg_size_pretty(sum(after_compression_total_bytes))   AS size_after
FROM chunk_compression_stats('$TABLE')
GROUP BY is_compressed;

-- Active policies
SELECT
  hypertable_name,
  proc_name          AS policy,
  schedule_interval,
  config
FROM timescaledb_information.jobs
WHERE hypertable_name IN ('$TABLE', '$CAGG')
ORDER BY hypertable_name, proc_name;

-- Continuous aggregate status
SELECT
  view_name,
  materialization_hypertable_name,
  finalized
FROM timescaledb_information.continuous_aggregates
WHERE view_name = '$CAGG';
SQL

ok "Optimization script complete."
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Update docker-compose.yml: remove '-c autovacuum=off' and tune memory settings."
echo "  2. Restart the container: docker compose up -d --force-recreate timescaledb"
echo "  3. Monitor background jobs: SELECT * FROM timescaledb_information.job_stats;"
echo "  4. Verify count speed: SELECT approximate_row_count('$TABLE');"
