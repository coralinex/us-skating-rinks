#!/usr/bin/env bash
# Shared settings for the pipeline scripts. Override via environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# docker-compose default. For the no-Docker helper (pipeline/local_db.sh) use
#   export DATABASE_URL=postgresql://localhost:54329/rinks
export DATABASE_URL="${DATABASE_URL:-postgresql://rinks:rinks@localhost:5432/rinks}"

export RAW_JSON="${RAW_JSON:-$ROOT/data/raw/rinks_overpass.json}"
export BUILD_DIR="${BUILD_DIR:-$ROOT/data/build}"
export PMTILES_OUT="${PMTILES_OUT:-$ROOT/web/public/rinks.pmtiles}"

# psql from Homebrew is keg-only (libpq / postgresql@NN).
if ! command -v psql >/dev/null && command -v brew >/dev/null; then
  for k in libpq postgresql@17 postgresql@18 postgresql@16; do
    d="$(brew --prefix)/opt/$k/bin"
    if [ -x "$d/psql" ]; then PATH="$d:$PATH"; break; fi
  done
fi
export CONTEXT_JSON="${CONTEXT_JSON:-$ROOT/data/raw/context_overpass.json}"
export CURATED_CSV="${CURATED_CSV:-$ROOT/data/holiday_rinks.csv}"
export BOUNDARY_DIR="${BOUNDARY_DIR:-$ROOT/data/boundaries}"
export CENSUS_YEAR="${CENSUS_YEAR:-2025}"
export WIKIDATA_JSON="${WIKIDATA_JSON:-$ROOT/data/raw/wikidata_websites.json}"
