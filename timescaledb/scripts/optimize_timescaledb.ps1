# =============================================================================
# TimescaleDB Optimization Script - biot_measurements (440M rows)
# PowerShell version
# =============================================================================
# Run from the grafana-timescale folder:
#   .\optimize_timescaledb.ps1
#
# To skip all confirmation prompts:
#   .\optimize_timescaledb.ps1 -AutoYes
# =============================================================================

param(
    [switch]$AutoYes
)

# ── Config ────────────────────────────────────────────────────────────────────
$EnvFile       = Join-Path $PSScriptRoot ".env"
$Container     = "timescaledb"
$Table         = "biot_measurements"
$Cagg          = "biot_hourly"

# Load .env
$DbUser = "tsdbadmin"; $DbName = "metrics"; $DbPassword = ""
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match '^\s*\w' -and $_ -notmatch '^\s*#' } | ForEach-Object {
        $parts = $_ -split '=', 2
        switch ($parts[0].Trim()) {
            'DB_USER'     { $DbUser     = $parts[1].Trim() }
            'DB_NAME'     { $DbName     = $parts[1].Trim() }
            'DB_PASSWORD' { $DbPassword = $parts[1].Trim() }
        }
    }
}

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Section($msg) {
    Write-Host ""
    Write-Host "== $msg ==" -ForegroundColor Cyan
}

function Write-Ok($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor White }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

function Confirm-Step($msg) {
    if ($AutoYes) { return $true }
    $ans = Read-Host "$msg [y/N]"
    return $ans -match '^[Yy]$'
}

# Run SQL, return trimmed scalar result
function Invoke-Sql($sql) {
    $result = docker exec -i $Container `
        sh -c "PGPASSWORD='$DbPassword' psql -U $DbUser -d $DbName -XAt -c `"$sql`"" 2>&1
    return ($result | Out-String).Trim()
}

# Run SQL, show formatted table output
function Invoke-SqlPretty($sql) {
    docker exec -i $Container `
        sh -c "PGPASSWORD='$DbPassword' psql -U $DbUser -d $DbName -X -c `"$sql`""
}

# Run a multi-line SQL block (heredoc alternative)
function Invoke-SqlBlock($sql) {
    $tmp = [System.IO.Path]::GetTempFileName() + ".sql"
    [System.IO.File]::WriteAllText($tmp, $sql, [System.Text.Encoding]::UTF8)
    docker cp $tmp "${Container}:/tmp/opt_block.sql" | Out-Null
    docker exec -i $Container `
        sh -c "PGPASSWORD='$DbPassword' psql -U $DbUser -d $DbName -X -f /tmp/opt_block.sql"
    Remove-Item $tmp -Force
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
Write-Section "Pre-flight checks"

$dockerRunning = docker info 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "Docker is not running."; exit 1 }

$containerState = docker inspect --format '{{.State.Running}}' $Container 2>&1
if ($containerState -ne "true") {
    Write-Error "Container '$Container' is not running. Start it with: docker compose up -d"
    exit 1
}
Write-Ok "Container '$Container' is running."

$tsVersion = Invoke-Sql "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';"
if (-not $tsVersion) {
    Write-Warn "Could not verify TimescaleDB extension via query (possible quoting issue) - continuing anyway."
} else {
    Write-Ok "TimescaleDB version: $tsVersion"
}

$rowEst = Invoke-Sql "SELECT approximate_row_count('$Table');"
if ($rowEst -match '^\d+$') {
    Write-Info "Approximate row count: $("{0:N0}" -f [long]$rowEst)"
} else {
    Write-Warn "Could not read row count (will continue): $rowEst"
}

# ── Step 1: VACUUM ANALYZE ────────────────────────────────────────────────────
Write-Section "Step 1 - VACUUM ANALYZE (refresh statistics)"
Write-Info "Reclaims dead tuples from bulk load and updates planner stats."
Write-Warn "Takes a few minutes on 440M rows."

if (Confirm-Step "Run VACUUM ANALYZE on $Table now?") {
    Invoke-SqlPretty "VACUUM (ANALYZE, VERBOSE) $Table;"
    Write-Ok "VACUUM ANALYZE complete."
} else {
    Write-Warn "Skipped. Run manually: VACUUM (ANALYZE, VERBOSE) $Table;"
}

# ── Step 2: Enable compression ────────────────────────────────────────────────
Write-Section "Step 2 - Enable chunk compression"

$comprEnabled = Invoke-Sql @"
SELECT compression_enabled FROM timescaledb_information.hypertables
WHERE hypertable_name = '$Table';
"@

if ($comprEnabled -eq "t") {
    Write-Ok "Compression already enabled on $Table."
} else {
    Write-Info "segmentby: pid, sid, measure_name | orderby: time DESC"
    if (Confirm-Step "Apply compression settings to $Table?") {
        Invoke-SqlPretty @"
ALTER TABLE $Table SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'pid, sid, measure_name',
    timescaledb.compress_orderby   = 'time DESC'
);
"@
        Write-Ok "Compression settings applied."
    }
}

# Add compression policy
$comprPolicy = Invoke-Sql @"
SELECT count(*) FROM timescaledb_information.jobs
WHERE hypertable_name = '$Table' AND proc_name = 'policy_compression';
"@

if ([int]$comprPolicy -gt 0) {
    Write-Ok "Compression policy already exists."
} else {
    if (Confirm-Step "Add auto-compression policy (compress chunks older than 7 days)?") {
        Invoke-SqlPretty "SELECT add_compression_policy('$Table', INTERVAL '7 days');"
        Write-Ok "Compression policy added."
    }
}

# ── Step 2b: Compress existing chunks ─────────────────────────────────────────
Write-Section "Step 2b - Compress existing chunks (incremental, batches of 10)"

$uncompressed = Invoke-Sql @"
SELECT count(*) FROM timescaledb_information.chunks
WHERE hypertable_name = '$Table'
  AND is_compressed = false
  AND range_end < NOW() - INTERVAL '7 days';
"@
Write-Info "Uncompressed chunks eligible: $uncompressed"

if ([int]$uncompressed -gt 0 -and (Confirm-Step "Compress existing chunks now? (safe to Ctrl+C and re-run)")) {
    Invoke-SqlBlock @"
DO \$\$
DECLARE
  chunk_rec  RECORD;
  compressed INT := 0;
  skipped    INT := 0;
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
      RAISE NOTICE 'Compressed % (total: %)', chunk_rec.chunk_name, compressed;
    EXCEPTION WHEN OTHERS THEN
      skipped := skipped + 1;
      RAISE WARNING 'Skipped %: %', chunk_rec.chunk_name, SQLERRM;
    END;
  END LOOP;
  RAISE NOTICE 'Done. Compressed: %, Skipped: %', compressed, skipped;
END;
\$\$;
"@
    Write-Ok "Chunk compression pass complete."
}

# ── Step 3: Chunk interval ────────────────────────────────────────────────────
Write-Section "Step 3 - Set chunk interval to 7 days (new chunks only)"

$currentInterval = Invoke-Sql @"
SELECT time_interval FROM timescaledb_information.dimensions
WHERE hypertable_name = '$Table';
"@
Write-Info "Current chunk interval: $currentInterval"

if (Confirm-Step "Change chunk interval to 7 days?") {
    Invoke-SqlPretty "SELECT set_chunk_time_interval('$Table', INTERVAL '7 days');"
    Write-Ok "Chunk interval updated to 7 days."
}

# ── Step 4: Continuous aggregate backfill ─────────────────────────────────────
Write-Section "Step 4 - Populate continuous aggregate ($Cagg)"

$caggExists = Invoke-Sql @"
SELECT count(*) FROM timescaledb_information.continuous_aggregates
WHERE view_name = '$Cagg';
"@

if ([int]$caggExists -eq 0) {
    Write-Warn "$Cagg does not exist - skipping."
} else {
    $caggRows = Invoke-Sql "SELECT count(*) FROM $Cagg;"
    Write-Info "$Cagg current row count: $caggRows"

    if ([long]$caggRows -eq 0) {
        Write-Warn "$Cagg is empty (created WITH NO DATA). Full backfill on 440M rows may take hours."
        Write-Warn "Recommended: run overnight or in a separate PowerShell window."
        if (Confirm-Step "Start backfill now?") {
            Invoke-SqlPretty "CALL refresh_continuous_aggregate('$Cagg', NULL, NOW());"
            Write-Ok "Backfill complete."
        } else {
            Write-Info "To run backfill manually in a new PowerShell window:"
            Write-Host "  docker exec -it $Container sh -c `"PGPASSWORD='$DbPassword' psql -U $DbUser -d $DbName -c \`"CALL refresh_continuous_aggregate('$Cagg', NULL, NOW());\`"`""
        }
    } else {
        Write-Ok "$Cagg already has data ($caggRows rows)."
    }

    # Refresh policy
    $caggPolicy = Invoke-Sql @"
SELECT count(*) FROM timescaledb_information.jobs
WHERE hypertable_name = '$Cagg'
  AND proc_name = 'policy_refresh_continuous_aggregate';
"@
    if ([int]$caggPolicy -eq 0) {
        if (Confirm-Step "Add hourly refresh policy to $Cagg?") {
            Invoke-SqlPretty @"
SELECT add_continuous_aggregate_policy('$Cagg',
    start_offset      => INTERVAL '3 hours',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour'
);
"@
            Write-Ok "Refresh policy added."
        }
    } else {
        Write-Ok "Refresh policy already exists on $Cagg."
    }
}

# ── Step 5: Retention policy ──────────────────────────────────────────────────
Write-Section "Step 5 - Retention policy on $Table"
Write-Info "Drops raw chunks older than 180 days."
Write-Warn "Only proceed if $Cagg backfill is complete!"

$retentionExists = Invoke-Sql @"
SELECT count(*) FROM timescaledb_information.jobs
WHERE hypertable_name = '$Table' AND proc_name = 'policy_retention';
"@

if ([int]$retentionExists -gt 0) {
    Write-Ok "Retention policy already exists on $Table."
} else {
    if (Confirm-Step "Add 180-day retention policy to $Table? (permanent data deletion)") {
        Invoke-SqlPretty "SELECT add_retention_policy('$Table', INTERVAL '180 days');"
        Write-Ok "Retention policy added."
    } else {
        Write-Info "Skipped. To add later:"
        Write-Host "  SELECT add_retention_policy('$Table', INTERVAL '180 days');"
    }
}

# ── Final status ──────────────────────────────────────────────────────────────
Write-Section "Final status"

Invoke-SqlBlock @"
SELECT
    h.hypertable_name,
    h.compression_enabled,
    d.time_interval          AS chunk_interval,
    approximate_row_count(h.hypertable_name::regclass) AS approx_rows
FROM timescaledb_information.hypertables h
JOIN timescaledb_information.dimensions d USING (hypertable_name)
WHERE h.hypertable_name = 'biot_measurements';

SELECT
    compression_status,
    count(*)                                             AS chunks,
    pg_size_pretty(sum(before_compression_total_bytes)) AS size_before,
    pg_size_pretty(sum(after_compression_total_bytes))  AS size_after
FROM chunk_compression_stats('biot_measurements')
GROUP BY compression_status;

SELECT hypertable_name, proc_name AS policy, schedule_interval, config
FROM timescaledb_information.jobs
WHERE hypertable_name IN ('biot_measurements', 'biot_hourly')
ORDER BY hypertable_name, proc_name;
"@

Write-Host ""
Write-Ok "Optimization complete."
Write-Host ""
Write-Host "Verify count speed with:" -ForegroundColor Cyan
Write-Host "  SELECT approximate_row_count('biot_measurements');"
Write-Host "  SELECT * FROM timescaledb_information.job_stats;"
