#!/usr/bin/env python3
"""
bulk_load_biot.py
─────────────────
Loads ALL CSV files from a directory into measurements, one file at a time.

Key features
────────────
• Resumable   — progress is saved to load_progress.json after every file.
                Re-run after a crash and it skips everything already done.
• Safe        — never truncates; uses ON CONFLICT DO NOTHING so re-runs are
                idempotent even for partially-loaded files.
• Retryable   — files that errored are retried on the next run (--retry-errors).
• Verbose log — load_errors.log captures the full traceback for every failure.

Usage
─────
  # First run (or resume after crash):
  python bulk_load_biot.py "C:\\AWS Dump (from BioT)\\tingo-TimeStream-export\\results"

  # Re-try files that previously errored:
  python bulk_load_biot.py <results_dir> --retry-errors

  # Dry-run: validate CSVs, print stats, no DB writes:
  python bulk_load_biot.py <results_dir> --dry-run

  # Override DB connection (defaults come from .env in cwd):
  python bulk_load_biot.py <results_dir> --host localhost --port 5432 \\
      --user tsdbadmin --password secret --dbname metrics

Requirements
────────────
  pip install pandas psycopg2-binary python-dotenv
"""

import argparse
import io
import json
import logging
import os
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import psycopg2
import psycopg2.extras
from dotenv import load_dotenv

# ── Constants ─────────────────────────────────────────────────────────────────

TABLE         = "measurements"
BATCH_SIZE    = 50_000   # used only for execute_values fallback
# Always store progress next to this script, regardless of working directory
_SCRIPT_DIR   = Path(__file__).parent
PROGRESS_FILE = _SCRIPT_DIR / "load_progress.json"
ERROR_LOG     = str(_SCRIPT_DIR / "load_errors.log")

# ── Logging ───────────────────────────────────────────────────────────────────

logging.basicConfig(
    filename=ERROR_LOG,
    level=logging.ERROR,
    format="%(asctime)s  %(levelname)s  %(message)s",
)

def log_error(filename: str, exc: Exception):
    logging.error("─── %s ───\n%s", filename, traceback.format_exc())


# ── Progress tracking ─────────────────────────────────────────────────────────

def load_progress(path: Path) -> dict:
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def save_progress(path: Path, progress: dict):
    path.write_text(json.dumps(progress, indent=2, ensure_ascii=False), encoding="utf-8")


def mark_done(progress: dict, filename: str, rows: int):
    progress[filename] = {
        "status":    "done",
        "rows":      rows,
        "finished":  datetime.now(timezone.utc).isoformat(),
    }


def mark_error(progress: dict, filename: str, error: str):
    progress[filename] = {
        "status":  "error",
        "error":   error,
        "failed":  datetime.now(timezone.utc).isoformat(),
    }


# ── DB helpers ────────────────────────────────────────────────────────────────

def make_conn(args):
    return psycopg2.connect(
        host=args.host, port=args.port,
        user=args.user, password=args.password,
        dbname=args.dbname,
        connect_timeout=15,
    )


def make_conn_with_retry(args, retries=20, delay=15):
    """Keep trying to connect until the DB comes back up (e.g. after a crash)."""
    for attempt in range(1, retries + 1):
        try:
            conn = make_conn(args)
            conn.autocommit = False
            if attempt > 1:
                print(f"  ✅ Reconnected after {attempt} attempt(s).")
            return conn
        except Exception as e:
            print(f"  ⚠️  DB unavailable (attempt {attempt}/{retries}): {e}")
            if attempt < retries:
                print(f"      Retrying in {delay}s — waiting for Docker to come back up...")
                time.sleep(delay)
    raise RuntimeError(f"Could not reconnect after {retries} attempts.")


def _drop_indexes(conn):
    """Dynamically drop ALL indexes on the measurements table before bulk load."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT indexname FROM pg_indexes
            WHERE tablename = %s AND schemaname = 'public'
        """, (TABLE,))
        indexes = [row[0] for row in cur.fetchall()]
        if not indexes:
            print("    No indexes found to drop.")
            return
        for idx in indexes:
            print(f"    Dropping: {idx}")
            cur.execute(f"DROP INDEX IF EXISTS {idx}")
    conn.commit()


def _recreate_indexes(conn):
    """Recreate indexes after bulk load. Faster to build in bulk than row-by-row."""
    sqls = [
        # No unique index — BioT data contains duplicate rows
        "CREATE INDEX IF NOT EXISTS idx_meas_time "
        "ON measurements (time DESC)",
        "CREATE INDEX IF NOT EXISTS idx_meas_pid_time "
        "ON measurements (pid, time DESC)",
        "CREATE INDEX IF NOT EXISTS idx_meas_sid_time "
        "ON measurements (sid, time DESC)",
        "CREATE INDEX IF NOT EXISTS idx_meas_metric_time "
        "ON measurements (measure_name, time DESC)",
        "CREATE INDEX IF NOT EXISTS idx_meas_pid_sid_metric_time "
        "ON measurements (pid, sid, measure_name, time DESC)",
    ]
    with conn.cursor() as cur:
        for sql in sqls:
            print(f"    Building: {sql.split('INDEX')[1].split('ON')[0].strip()}...")
            cur.execute(sql)
            conn.commit()


def ensure_table(conn):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT EXISTS (SELECT FROM information_schema.tables "
            "WHERE table_name = %s)",
            (TABLE,),
        )
        if not cur.fetchone()[0]:
            print(f"\n❌  Table '{TABLE}' does not exist in the database.")
            print("    Run 03_reset_biot_only.sql first, then retry.")
            sys.exit(1)
    print(f"  ✅ Table '{TABLE}' confirmed.")


# ── CSV helpers ───────────────────────────────────────────────────────────────

RENAME_MAP = {
    "measure_value::double": "value",
    "startTime":             "start_time",
}
REQUIRED_COLS = {"time", "pid", "sid", "usid", "measure_name", "value"}
INSERT_COLS   = ["time", "pid", "sid", "usid", "start_time", "measure_name", "value"]


def load_csv(filepath: Path) -> pd.DataFrame:
    df = pd.read_csv(filepath, low_memory=False)
    df = df.rename(columns=RENAME_MAP)

    missing = REQUIRED_COLS - set(df.columns)
    if missing:
        raise ValueError(f"Missing columns: {missing}  (found: {list(df.columns)})")

    # Ensure start_time exists even if column was absent
    if "start_time" not in df.columns:
        df["start_time"] = pd.NaT

    df["time"]       = pd.to_datetime(df["time"],       utc=True, errors="coerce")
    df["start_time"] = pd.to_datetime(df["start_time"], utc=True, errors="coerce")

    bad = df["time"].isna().sum()
    if bad:
        df = df[df["time"].notna()]

    return df[INSERT_COLS]


def _clean(val):
    try:
        if pd.isnull(val):
            return None
    except (TypeError, ValueError):
        pass
    return val if val is not None else None


# ── Insertion ─────────────────────────────────────────────────────────────────

def insert_df(conn, df: pd.DataFrame, fast: bool = False) -> int:
    """
    Insert a DataFrame using COPY (fast=True) or execute_values (fast=False).
    COPY is ~10-20x faster but skips ON CONFLICT — safe for fresh bulk loads.
    execute_values with ON CONFLICT DO NOTHING is safe for re-runs/top-ups.
    """
    if fast:
        return _copy_insert(conn, df)
    else:
        return _values_insert(conn, df)


def _copy_insert(conn, df: pd.DataFrame) -> int:
    """Use PostgreSQL COPY FROM STDIN — fastest possible bulk load."""
    buf = io.StringIO()
    # Write as TSV (tab-separated) to avoid comma issues in values
    df.to_csv(buf, index=False, header=False, sep='\t', na_rep='\\N',
              date_format='%Y-%m-%d %H:%M:%S%z')
    buf.seek(0)

    with conn.cursor() as cur:
        cur.copy_expert(
            f"COPY {TABLE} (time, pid, sid, usid, start_time, measure_name, value) "
            f"FROM STDIN WITH (FORMAT text, DELIMITER E'\\t', NULL '\\N')",
            buf
        )
    conn.commit()
    return len(df)


def _values_insert(conn, df: pd.DataFrame) -> int:
    """Batched INSERT with ON CONFLICT DO NOTHING — safe for re-runs."""
    INSERT_SQL = f"""
        INSERT INTO {TABLE} (time, pid, sid, usid, start_time, measure_name, value)
        VALUES %s
        ON CONFLICT DO NOTHING
    """
    rows = [tuple(_clean(v) for v in row)
            for row in df.itertuples(index=False, name=None)]

    with conn.cursor() as cur:
        psycopg2.extras.execute_values(cur, INSERT_SQL, rows, page_size=BATCH_SIZE)
    conn.commit()
    return len(rows)


# ── Main ──────────────────────────────────────────────────────────────────────

def parse_args():
    load_dotenv()
    p = argparse.ArgumentParser(description="Bulk-load all BioT CSVs into TimescaleDB")
    p.add_argument("results_dir",  help="Directory containing the CSV export files")
    p.add_argument("--host",          default=os.getenv("DB_HOST",     "localhost"))
    p.add_argument("--port",          default=int(os.getenv("DB_PORT", "5432")), type=int)
    p.add_argument("--user",          default=os.getenv("DB_USER",     "tsdbadmin"))
    p.add_argument("--password",      default=os.getenv("DB_PASSWORD", ""))
    p.add_argument("--dbname",        default=os.getenv("DB_NAME",     "metrics"))
    p.add_argument("--dry-run",       action="store_true",
                   help="Parse CSVs and print stats; no DB writes")
    p.add_argument("--retry-errors",  action="store_true",
                   help="Re-attempt files that previously errored")
    p.add_argument("--batch-size",    default=BATCH_SIZE, type=int,
                   help=f"Rows per INSERT batch (default {BATCH_SIZE})")
    p.add_argument("--fast",          action="store_true",
                   help="Use COPY instead of INSERT and drop indexes during load "
                        "(10-20x faster; use for fresh loads, not top-ups)")
    return p.parse_args()


def main():
    args    = parse_args()
    results = Path(args.results_dir)
    if not results.is_dir():
        print(f"❌  Not a directory: {results}")
        sys.exit(1)

    csv_files = sorted(results.glob("*.csv"))
    if not csv_files:
        print(f"❌  No CSV files found in {results}")
        sys.exit(1)

    total_files = len(csv_files)
    print(f"\n📂  Found {total_files:,} CSV files in {results}")

    # ── Load progress ──────────────────────────────────────────────────────
    progress_path = PROGRESS_FILE  # already a Path
    print(f"📁  Progress file : {progress_path.resolve()}")
    progress      = load_progress(progress_path)

    done_count  = sum(1 for v in progress.values() if v["status"] == "done")
    error_count = sum(1 for v in progress.values() if v["status"] == "error")
    print(f"📋  Progress file: {done_count:,} done, {error_count:,} errored previously")

    # Decide which files to process
    skip_statuses = {"done"}
    if not args.retry_errors:
        skip_statuses.add("error")

    pending = [f for f in csv_files
               if progress.get(f.name, {}).get("status") not in skip_statuses]

    if not pending:
        print("\n✅  Nothing left to process — all files are already done.")
        _print_summary(progress, total_files)
        return

    print(f"⏳  {len(pending):,} files to process  "
          f"({'dry run — no writes' if args.dry_run else 'will insert into DB'})\n")

    # ── Connect ────────────────────────────────────────────────────────────
    conn = None
    if not args.dry_run:
        print(f"🔌  Connecting to {args.host}:{args.port}/{args.dbname}...")
        try:
            conn = make_conn_with_retry(args)
            ensure_table(conn)
        except Exception as e:
            print(f"❌  Cannot connect to database: {e}")
            sys.exit(1)

        if args.fast:
            print("\n⚡  Fast mode: dropping indexes before load (will recreate after)...")
            _drop_indexes(conn)
            print("    Indexes dropped. Loading with COPY...\n")

    # ── Process files ──────────────────────────────────────────────────────
    session_rows   = 0
    session_errors = 0
    t_session      = time.time()

    for idx, filepath in enumerate(pending, 1):
        fname   = filepath.name
        pct     = idx / len(pending) * 100
        overall = (done_count + idx) / total_files * 100

        print(f"[{idx:>5}/{len(pending)}  {pct:5.1f}%  overall {overall:5.1f}%]  {fname}")

        try:
            df = load_csv(filepath)
            rows = len(df)

            if args.dry_run:
                print(f"         rows={rows:,}  time={df['time'].min()} → {df['time'].max()}")
                mark_done(progress, fname, rows)
            else:
                # Reconnect if connection dropped (waits for Docker to recover)
                try:
                    conn.isolation_level  # cheap check
                except Exception:
                    print("  ⚠️  Connection lost — waiting for DB to come back up...")
                    conn = make_conn_with_retry(args)

                inserted = insert_df(conn, df, fast=args.fast)
                session_rows += inserted
                elapsed  = time.time() - t_session
                rps      = session_rows / elapsed if elapsed else 0
                print(f"         ✅ {inserted:,} rows  "
                      f"({session_rows:,} this session  {rps:,.0f} rows/s)")
                mark_done(progress, fname, inserted)

        except Exception as exc:
            session_errors += 1
            short = str(exc)[:120]
            print(f"         ❌ ERROR: {short}")
            print(f"            (full traceback → {ERROR_LOG})")
            log_error(fname, exc)
            mark_error(progress, fname, short)
            # Try to roll back any partial work
            if conn and not args.dry_run:
                try:
                    conn.rollback()
                except Exception:
                    pass

        finally:
            save_progress(progress_path, progress)

    # ── Done ───────────────────────────────────────────────────────────────
    if conn and args.fast and not args.dry_run:
        print("\n🔧  Recreating indexes (this may take several minutes on large datasets)...")
        _recreate_indexes(conn)
        print("    Indexes recreated.")

    if conn:
        conn.close()

    elapsed_total = time.time() - t_session
    print(f"\n{'─'*60}")
    print(f"🎉  Session complete in {elapsed_total/60:.1f} min")
    print(f"    Rows inserted this run : {session_rows:,}")
    print(f"    Files errored this run : {session_errors}")
    _print_summary(progress, total_files)

    if session_errors:
        print(f"\n⚠️   {session_errors} file(s) failed — check {ERROR_LOG}")
        print(f"    Re-run with --retry-errors to attempt them again.")


def _print_summary(progress: dict, total_files: int):
    done   = sum(1 for v in progress.values() if v["status"] == "done")
    errors = sum(1 for v in progress.values() if v["status"] == "error")
    total_rows = sum(v.get("rows", 0) for v in progress.values() if v["status"] == "done")
    print(f"\n📊  Overall progress:")
    print(f"    Done    : {done:>5,} / {total_files:,} files")
    print(f"    Errors  : {errors:>5,} files")
    print(f"    Rows    : {total_rows:,} total inserted")


if __name__ == "__main__":
    main()
