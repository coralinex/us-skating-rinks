#!/usr/bin/env bash
# Raw Overpass JSON -> GeoJSONSeq -> ogr2ogr -> PostGIS staging table
# (rinks_raw), then db/transform.sql cleans it into `rinks`.
source "$(dirname "$0")/env.sh"

mkdir -p "$BUILD_DIR"
SEQ="$BUILD_DIR/rinks_raw.geojsonl"

jq -c -f "$ROOT/pipeline/overpass_to_geojson.jq" "$RAW_JSON" > "$SEQ"
echo "Converted $(wc -l < "$SEQ" | tr -d ' ') features"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$ROOT/db/schema.sql"

ogr2ogr -f PostgreSQL "PG:$DATABASE_URL" "GeoJSONSeq:$SEQ" \
  -nln rinks_raw -overwrite \
  -nlt GEOMETRY -a_srs EPSG:4326 \
  -lco GEOMETRY_NAME=geom -lco FID=ogc_fid -lco SPATIAL_INDEX=NONE

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$ROOT/db/transform.sql"
