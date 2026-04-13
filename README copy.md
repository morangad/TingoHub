# TingoHub — Grafana + TimescaleDB Stack

Self-contained Grafana + TimescaleDB setup for BioT measurement data, deployable
to an Ubuntu server or a Windows sandbox via Docker.

---

## Layout

```
TingoHub/
├── docker-compose.yml          Both services, volumes, network
├── .env.example                Template — copy to .env and fill in secrets
├── manage.sh / manage.ps1      Lifecycle helpers (Linux / Windows)
│
├── timescaledb/
│   ├── init/
│   │   └── 01_schema.sql       Runs once on first container boot
│   └── scripts/
│       ├── bulk_load_biot.py       Resumable BioT CSV bulk loader
│       ├── optimize_timescaledb.sh Post-load tuning (Linux)
│       └── optimize_timescaledb.ps1 Post-load tuning (Windows)
│
└── grafana/
    ├── provisioning/
    │   ├── datasources/timescaledb.yml   Auto-wires Grafana → TimescaleDB
    │   └── dashboards/dashboards.yml     Auto-loads dashboards folder
    └── dashboards/
        └── tingo_device_data.json        Main device-data dashboard
```

---

## Prerequisites

- Docker Engine + Compose plugin (Linux) or Docker Desktop (Windows)
- Ports **3000** (Grafana) and **5432** (Postgres) free on the host

---

## Quick start

```bash
cp .env.example .env        # edit DB_PASSWORD and GRAFANA_PASSWORD
chmod +x manage.sh
./manage.sh up
```

Windows (PowerShell):

```powershell
Copy-Item .env.example .env   # edit passwords
.\manage.ps1 up
```

First boot runs `timescaledb/init/01_schema.sql`, which:
- Enables the `timescaledb` extension
- Creates the `measurements` hypertable (daily chunks)
- Creates indexes tuned for Grafana query patterns

Grafana binds to `0.0.0.0:3000` so it is reachable from any LAN host:
`http://<server-ip>:3000` — log in with the credentials from `.env`.

---

## Schema

```
measurements  (hypertable, 1-day chunks)
  time          TIMESTAMPTZ     ← partition key
  pid           TEXT            ← patient id
  sid           TEXT            ← device / session id
  usid          TEXT            ← usage session id
  start_time    TIMESTAMPTZ
  measure_name  TEXT
  value         DOUBLE PRECISION

Indexes:
  idx_measurements_unique         (time, pid, sid, usid, measure_name) UNIQUE
  idx_measurements_pid_time       (pid, time DESC)
  idx_measurements_sid_time       (sid, time DESC)
  idx_measurements_measure_time   (measure_name, time DESC)
```

---

## Loading BioT CSV data

```bash
pip install pandas psycopg2-binary python-dotenv
python timescaledb/scripts/bulk_load_biot.py /path/to/biot/export/results
```

Resumable: progress is persisted to `load_progress.json` in the script
directory, and already-loaded files are skipped on re-run. Use
`--retry-errors` to retry failures, `--dry-run` to validate without writing.

Connection defaults come from `.env`; override with `--host / --port / --user /
--password / --dbname` if needed.

---

## Post-load tuning

After a large bulk load, run the optimizer to compress old chunks and refresh
statistics:

```bash
timescaledb/scripts/optimize_timescaledb.sh
# or on Windows
timescaledb/scripts/optimize_timescaledb.ps1
```

---

## Management commands

| Command | Description |
|---|---|
| `./manage.sh up` | Start everything |
| `./manage.sh down` | Stop (data preserved) |
| `./manage.sh reset` | Stop + **delete all volumes** |
| `./manage.sh logs [service]` | Follow logs |
| `./manage.sh status` | Containers + URLs |
| `./manage.sh psql` | psql shell inside the DB container |

---

## Adding dashboards

Drop a Grafana dashboard JSON file into `grafana/dashboards/`. Grafana polls
that folder every 30 s and auto-imports new files — no restart required.

---

## LAN access notes

Both services bind to `0.0.0.0`. Open the relevant ports on the host firewall:

```bash
# Ubuntu
sudo ufw allow 3000/tcp   # Grafana
sudo ufw allow 5432/tcp   # TimescaleDB (only if external DB access needed)
```

If you only want Grafana on the LAN (not the DB), remove the `ports` section
from the `timescaledb` service in `docker-compose.yml`. Grafana will still
reach the DB over the internal Docker network.
