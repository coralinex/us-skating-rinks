#!/usr/bin/env bash
# PostGIS -> GeoJSONSeq -> tippecanoe -> rinks.pmtiles
# Tiles are exported from the `rinks_tiles` view (the same view Martin serves
# in realtime mode), never from the raw GeoJSON.
source "$(dirname "$0")/env.sh"

mkdir -p "$BUILD_DIR" "$(dirname "$PMTILES_OUT")"
SEQ="$BUILD_DIR/rinks.geojsonseq"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "
  SELECT json_build_object(
           'type', 'Feature',
           'geometry', ST_AsGeoJSON(geom, 6)::json,
           'properties', json_strip_nulls((to_jsonb(t) - 'geom')::json))
  FROM rinks_tiles t
  ORDER BY id" > "$SEQ"

echo "Exported $(wc -l < "$SEQ" | tr -d ' ') features"

# -r1 keeps every point at every zoom (no dropping at low zooms).
tippecanoe -o "$PMTILES_OUT" --force --quiet \
  -l rinks -Z0 -z14 -r1 \
  --no-tile-size-limit --no-feature-limit \
  -n "US ice rinks" -A "© OpenStreetMap contributors" \
  "$SEQ"

ls -lh "$PMTILES_OUT"
