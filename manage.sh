#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# manage.sh — start, stop, reset, and inspect the Grafana + TimescaleDB stack
# Usage: ./manage.sh [up|down|reset|logs [service]|status|ip|psql]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

COMPOSE="docker compose"
ENV_FILE=".env"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

GRAFANA_PORT="${GRAFANA_PORT:-3000}"

print_urls() {
  LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_LAN_IP")
  echo ""
  echo "  Grafana:      http://${LAN_IP}:${GRAFANA_PORT}"
  echo "  TimescaleDB:  ${LAN_IP}:5432  (user: ${DB_USER:-tsdbadmin}, db: ${DB_NAME:-metrics})"
  echo ""
}

case "${1:-up}" in
  up)
    echo "Starting stack..."
    $COMPOSE up -d --build
    echo "Waiting for services to become healthy..."
    sleep 8
    $COMPOSE ps
    print_urls
    echo "  Login: ${GRAFANA_USER:-admin} / (see .env for password)"
    ;;

  down)
    echo "Stopping stack (data volumes preserved)..."
    $COMPOSE down
    ;;

  reset)
    echo "WARNING: Resetting stack — ALL DATA WILL BE DELETED. Ctrl-C to abort."
    sleep 5
    $COMPOSE down -v --remove-orphans
    echo "Reset complete. Run './manage.sh up' to start fresh."
    ;;

  logs)
    SERVICE="${2:-}"
    $COMPOSE logs -f --tail=100 $SERVICE
    ;;

  status)
    $COMPOSE ps
    print_urls
    ;;

  ip)
    print_urls
    ;;

  psql)
    echo "Connecting to TimescaleDB as ${DB_USER:-tsdbadmin}..."
    $COMPOSE exec timescaledb psql -U "${DB_USER:-tsdbadmin}" -d "${DB_NAME:-metrics}"
    ;;

  *)
    echo "Usage: $0 [up|down|reset|logs [service]|status|ip|psql]"
    exit 1
    ;;
esac
