#!/usr/bin/env bash
# Raw Overpass JSON -> GeoJSONSeq -> ogr2ogr -> PostGIS staging table
# (rinks_raw), then db/transform.sql cleans it into `rinks`.
source "$(dirname "$0")/env.sh"

mkdir -p "$BUILD_DIR"
SEQ="$BUILD_DIR/rinks_raw.geojsonl"
CTX_SEQ="$BUILD_DIR/context_raw.geojsonl"

jq -c -f "$ROOT/pipeline/overpass_to_geojson.jq" "$RAW_JSON" > "$SEQ"
echo "Converted $(wc -l < "$SEQ" | tr -d ' ') rinks"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$ROOT/db/schema.sql"

load() {  # load <geojsonl> <table>
  ogr2ogr -f PostgreSQL "PG:$DATABASE_URL" "GeoJSONSeq:$1" \
    -nln "$2" -overwrite \
    -nlt GEOMETRY -a_srs EPSG:4326 \
    -lco GEOMETRY_NAME=geom -lco FID=ogc_fid -lco SPATIAL_INDEX=GIST
}
load "$SEQ" rinks_raw

# Context (named facilities/grounds around rinks) is optional: without it the
# transform still runs, rinks just can't inherit names/websites from them.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c "DROP TABLE IF EXISTS rinks_context_raw"
if [ -s "$CONTEXT_JSON" ]; then
  jq -c --arg relbox 1 -f "$ROOT/pipeline/overpass_to_geojson.jq" "$CONTEXT_JSON" > "$CTX_SEQ"
  echo "Converted $(wc -l < "$CTX_SEQ" | tr -d ' ') context features"
fi
if [ -s "$CTX_SEQ" ]; then
  load "$CTX_SEQ" rinks_context_raw
else
  echo "No context file ($CONTEXT_JSON); run pipeline/fetch_overpass.sh to get one." >&2
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c \
    "CREATE TABLE rinks_context_raw (osm_type text, osm_id bigint, tags text, geom geometry(Geometry, 4326))"
fi

# Curated holiday rinks (not in OSM). Optional, like the context file.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c "TRUNCATE rinks_curated_raw"
if [ -s "$CURATED_CSV" ]; then
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "\\copy rinks_curated_raw FROM '$CURATED_CSV' WITH (FORMAT csv, HEADER true)"
  echo "Loaded $(($(wc -l < "$CURATED_CSV") - 1)) curated rinks"
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$ROOT/db/transform.sql"
