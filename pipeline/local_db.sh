#!/usr/bin/env bash
# No-Docker alternative to `docker compose up -d db`: a throwaway Postgres
# cluster in .local/pgdata using a Homebrew PostgreSQL + PostGIS install.
#   pipeline/local_db.sh start|stop|status
#   export DATABASE_URL=postgresql://localhost:54329/rinks
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGDATA="$ROOT/.local/pgdata"
PORT="${PGPORT:-54329}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"   # macOS: Postgres refuses to start without a valid locale

# Homebrew's postgresql@NN is keg-only; put its binaries on PATH if needed.
if ! command -v pg_ctl >/dev/null || ! command -v postgres >/dev/null; then
  for v in 17 18 16; do
    d="$(brew --prefix 2>/dev/null)/opt/postgresql@$v/bin"
    if [ -x "$d/postgres" ]; then PATH="$d:$PATH"; break; fi
  done
fi

case "${1:-start}" in
  start)
    if [ ! -d "$PGDATA" ]; then
      mkdir -p "$ROOT/.local"
      initdb -D "$PGDATA" --auth=trust --encoding=UTF8 >/dev/null
    fi
    pg_ctl -D "$PGDATA" -o "-p $PORT -c listen_addresses=localhost" \
           -l "$ROOT/.local/postgres.log" -w start
    createdb -h localhost -p "$PORT" rinks 2>/dev/null || true
    echo "export DATABASE_URL=postgresql://localhost:$PORT/rinks"
    ;;
  stop)   pg_ctl -D "$PGDATA" -m fast stop ;;
  status) pg_ctl -D "$PGDATA" status ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
