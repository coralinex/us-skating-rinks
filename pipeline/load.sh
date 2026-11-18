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

# Census boundaries (pipeline/fetch_boundaries.sh). Loaded once; set
# RELOAD_BOUNDARIES=1 after downloading a newer vintage.
for layer in state county place; do
  zip="$BOUNDARY_DIR/$layer/cb_${CENSUS_YEAR}_us_${layer}_500k.zip"
  have="$(psql "$DATABASE_URL" -Atq -c "SELECT to_regclass('census_$layer') IS NOT NULL")"
  if [ -s "$zip" ] && { [ "$have" != t ] || [ "${RELOAD_BOUNDARIES:-0}" = 1 ]; }; then
    echo "Loading Census $layer boundaries ..."
    ogr2ogr -f PostgreSQL "PG:$DATABASE_URL" "/vsizip/$zip" \
      -nln "census_$layer" -overwrite -t_srs EPSG:4326 -nlt PROMOTE_TO_MULTI \
      -ct_opt WARN_ABOUT_DIFFERENT_COORD_OP=NO \
      -select "$( [ $layer = state ] && echo STUSPS,NAME || echo NAME,NAMELSAD,STUSPS )" \
      -lco GEOMETRY_NAME=geom -lco FID=gid -lco SPATIAL_INDEX=GIST
  elif [ "$have" != t ]; then
    echo "No Census $layer boundaries ($zip); run pipeline/fetch_boundaries.sh." >&2
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c \
      "CREATE TABLE census_$layer (gid serial PRIMARY KEY, name text, namelsad text, stusps text,
                                   geom geometry(MultiPolygon, 4326))"
  fi
done

# Wikidata websites/addresses (pipeline/fetch_wikidata.sh). Optional.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c "TRUNCATE rinks_wikidata_raw"
if [ -s "$WIKIDATA_JSON" ]; then
  jq -r '.[] | [.qid, .website, .address] | @csv' "$WIKIDATA_JSON" \
    | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c "\\copy rinks_wikidata_raw FROM STDIN WITH (FORMAT csv)"
  echo "Loaded $(jq length "$WIKIDATA_JSON") Wikidata items"
fi

# Curated holiday rinks (not in OSM). Optional, like the context file.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c "TRUNCATE rinks_curated_raw"
if [ -s "$CURATED_CSV" ]; then
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "\\copy rinks_curated_raw FROM '$CURATED_CSV' WITH (FORMAT csv, HEADER true)"
  echo "Loaded $(($(wc -l < "$CURATED_CSV") - 1)) curated rinks"
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$ROOT/db/transform.sql"
