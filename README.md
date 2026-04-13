# TingoHub

Tingo Medical's internal platform for managing the full Fusion device lifecycle — covering manufacturing, laboratory experiments, and clinical trials.

## Tech Stack

- **Backend:** FastAPI (Python)
- **Database:** PostgreSQL + TimescaleDB
- **ORM / Migrations:** SQLAlchemy + Alembic
- **UI:** Jinja2 + HTMX + AG Grid
- **Infrastructure:** Docker + Docker Compose

## Environment Setup

Copy the example env file and fill in the values:

```bash
cp .env.example .env
```

## Requirements

### Production

Install runtime dependencies:

```bash
pip install -r requirements.txt
```

### Development

Install dev tools (linting, type checking) in addition to production dependencies:

```bash
pip install -r requirements.txt
pip install -r requirements-dev.txt
```