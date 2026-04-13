# TingoHub — Claude Project Context

## What is TingoHub?
TingoHub is Tingo Medical's internal platform, replacing the BioT SaaS platform.
It manages the full **Fusion device lifecycle** (CGM + Insulin Pump) — covering manufacturing, laboratory experiments, and clinical trials.

The platform runs entirely on a **company-owned on-premise Ubuntu server**, built on open source technologies. All data, business logic, and infrastructure are owned and operated by Tingo Medical.

> ⚠️ The platform name is **TingoHub** — not FusionHub. Use TingoHub consistently in all code, comments, and documentation.

---

## Technology Stack

| Layer | Technology | Notes |
|---|---|---|
| OS | Ubuntu Server | On-premise, replaces Windows |
| Containerization | Docker + Docker Compose | Single `docker-compose up` starts everything |
| Application server | FastAPI (Python) | REST API, business logic, RBAC enforcement |
| Relational DB | PostgreSQL | All structured entities |
| Time-series DB | TimescaleDB | Extension on PostgreSQL — glucose, current, temperature measurements |
| Visualization | Grafana | Self-hosted, connects to PostgreSQL/TimescaleDB |
| Auth | Keycloak | User management, login, token issuance (added in Phase 2) |
| Background tasks | Celery + Redis | Async: file ingestion, signal analysis, versioning (Phase 3) |
| Schema management | SQLAlchemy + Alembic | Code-defined models, migrations tracked in Git |
| Web UI | Jinja2 + HTMX + AG Grid | Server-rendered, no React/JS build pipeline |
| CI/CD | GitHub Actions | Build verification now; deployment automation later |

**No React.** The UI is Jinja2 + HTMX + AG Grid — server-side rendered, form-heavy, internal tool. Do not suggest React or a JS build pipeline.

---

## System Architecture

All services run as Docker containers on a single on-premise server.

```
┌─────────────────────────────────────────────────────────────┐
│                  Tingo On-Premise Server                    │
│                                                             │
│  ┌─────────────┐        ┌─────────────────────────────┐    │
│  │   Web UI    │◄──────►│     FastAPI App Server      │    │
│  │             │        │  - REST API                 │    │
│  └─────────────┘        │  - Business Logic           │    │
│                         │  - RBAC Enforcement         │    │
│  ┌─────────────┐        │  - Background Tasks(Celery) │    │
│  │   Grafana   │◄──┐    └──────────────┬──────────────┘    │
│  │ (self-host) │   │                   │                   │
│  └─────────────┘   │    ┌──────────────▼──────────────┐    │
│                    │    │          Data Layer         │    │
│  ┌─────────────┐   ├────┤  PostgreSQL + TimescaleDB   │    │
│  │  Keycloak   │   │    │  Local File Storage         │    │
│  └─────────────┘   │    └─────────────────────────────┘    │
│                    │                                        │
│  ┌─────────────┐   │                                        │
│  │    Redis    │───┘                                        │
│  └─────────────┘                                            │
└─────────────────────────────────────────────────────────────┘
```

---

## Roles (RBAC)

Four roles are defined in Keycloak and enforced in FastAPI:

| Role | Description |
|---|---|
| `admin` | Full access |
| `engineer` | Device and experiment workflows |
| `lab_technician` | Lab experiment data entry and results |
| `clinical` | Clinical trial data, read-heavy |

RBAC is enforced at the route level in FastAPI. In Phase 2, role checks are implemented as application-layer dependencies (stubbed tokens — no Keycloak integration yet). Keycloak is wired in during Phase 3.

---

## Project Phases

| Phase | Focus | Status |
|---|---|---|
| Phase 1 | Server setup, POC, schema definition | ✅ Done |
| Phase 2 | Data migration + full REST API (no UI yet) | 🔄 In progress |
| Phase 3 | Authentication + Web UI | ⬜ Upcoming |
| Phase 4 | Business logic (Celery, Lambda migration) | ⬜ Upcoming |
| Phase 5 | Cutover and stabilization | ⬜ Upcoming |

### Current Focus: Phase 2, Step 2 — REST API

Goals:
- Implement REST API endpoints for all core entity types (CRUD)
- Verify all routes using FastAPI's `/docs`
- Implement RBAC enforcement at the route level (role checks, without full auth UI yet)

---

## Docker Compose Evolution

| Phase | Services |
|---|---|
| Phase 1 | PostgreSQL + TimescaleDB, Grafana, FastAPI |
| Phase 2 | + Keycloak |
| Phase 3 | + Redis, Celery worker |

---

## Reference Codebase

The previous BioT implementation lives in the **PluginHub-Generic** repo (GitHub: `tingoprojects/PluginHub-Generic`, branch: `dev`).
Use it as a **reference only** — for patterns, entity structures, and business logic. Do not copy it directly; TingoHub is a clean rewrite.

When working on a specific entity or feature, the developer may share relevant BioT files as context. Treat them as reference material, not source of truth.

---

## Key Conventions

- **Python** throughout — FastAPI, SQLAlchemy, Alembic, Celery
- **SQLAlchemy models** define the schema; **Alembic** manages migrations
- All schema changes go through Alembic migrations, tracked in Git
- API routes are verified via FastAPI's built-in `/docs` (Swagger UI)
- All services run as Docker containers — no services installed directly on the host OS
- Branch strategy: work on `dev`, merge to `main` for releases

## Coding Standards

- **Type hints are required** on all variables, function parameters, and return values
- Use `str | None` (union syntax) instead of `Optional[str]`
- All environment variables are loaded exclusively through `config.py` — no `os.getenv()` calls elsewhere

---

## Release Milestones (from design doc)

| # | What | Target |
|---|---|---|
| 1 | Full data dump + validation | 1/4/26 ✅ |
| 2 | DB servers up | 14/4/26 |
| 3 | Local Grafana server | 20/4/26 |
| 4 | Offline backend & business logic | TBD |
| 5 | Full live backend server (REST API) | TBD |
| 6 | Authentication & Web UI | TBD |