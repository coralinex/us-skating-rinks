#!/usr/bin/env bash
# Fetch US ice rinks from OpenStreetMap via Overpass and cache the raw JSON.
# The raw response is kept in data/raw/ so the rest of the pipeline can be
# re-run without hitting Overpass again.
source "$(dirname "$0")/env.sh"

OVERPASS_URL="${OVERPASS_URL:-https://overpass-api.de/api/interpreter}"
mkdir -p "$(dirname "$RAW_JSON")"

# `out tags geom` returns node coordinates, full way geometry (for footprints)
# and a bounding box for ways/relations.
read -r -d '' QUERY <<'OQL' || true
[out:json][timeout:300];
area["ISO3166-1"="US"][admin_level=2]->.us;
(
  nwr["leisure"="ice_rink"](area.us);
  nwr["sport"="ice_skating"]["leisure"~"sports_centre|pitch"](area.us);
);
out tags geom;
OQL

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Querying $OVERPASS_URL ..."
curl --fail --silent --show-error --max-time 600 \
     -A "ice-rink-map-pipeline/1.0" \
     --data-urlencode "data=$QUERY" \
     -o "$tmp" "$OVERPASS_URL"

# Overpass reports timeouts in-band with HTTP 200; refuse to cache those.
if ! jq -e '.elements | length > 0' "$tmp" >/dev/null; then
  echo "Overpass returned no elements:" >&2
  jq -r '.remark // "unknown error"' "$tmp" >&2 || head -c 500 "$tmp" >&2
  echo "Try again later, set OVERPASS_URL to a mirror, or split the query by state." >&2
  exit 1
fi

mv "$tmp" "$RAW_JSON"
trap - EXIT
echo "Saved $(jq '.elements | length' "$RAW_JSON") elements to $RAW_JSON"
