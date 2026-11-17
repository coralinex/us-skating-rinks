#!/usr/bin/env bash
# Fetch US ice rinks from OpenStreetMap via Overpass and cache the raw JSON.
# Two files are written to data/raw/ so the rest of the pipeline can be re-run
# without hitting Overpass again:
#   rinks_overpass.json    the rinks themselves
#   context_overpass.json  named facilities/grounds around them (arena
#                          buildings, sports centres, parks, schools). OSM
#                          often puts the real name, website and address on
#                          these, while the rink is just "Rink 1" or unnamed.
source "$(dirname "$0")/env.sh"

OVERPASS_URL="${OVERPASS_URL:-https://overpass-api.de/api/interpreter}"
mkdir -p "$(dirname "$RAW_JSON")"

read -r -d '' RINKS <<'OQL' || true
area["ISO3166-1"="US"][admin_level=2]->.us;
(
  nwr["leisure"="ice_rink"](area.us);
  nwr["sport"="ice_skating"]["leisure"~"sports_centre|pitch"](area.us);
)->.rinks;
OQL

# `out tags geom` returns node coordinates, full way geometry (for footprints)
# and a bounding box for ways/relations.
RINKS_QUERY="[out:json][timeout:300];
$RINKS
.rinks out tags geom;"

fetch() {  # fetch <query> <output file>
  local tmp; tmp="$(mktemp)"
  echo "Querying $OVERPASS_URL -> $(basename "$2") ..."
  curl --fail --silent --show-error --max-time 900 --retry 4 --retry-delay 20 --retry-all-errors \
       -A "ice-rink-map-pipeline/1.0" \
       --data-urlencode "data=$1" \
       -o "$tmp" "$OVERPASS_URL"
  # Overpass reports timeouts in-band with HTTP 200; refuse to cache those.
  if ! jq -e --argjson min "$([ "${ALLOW_EMPTY:-0}" = 1 ] && echo 0 || echo 1)" '.elements | length >= $min' "$tmp" >/dev/null; then
    echo "Overpass returned no elements:" >&2
    jq -r '.remark // "unknown error"' "$tmp" >&2 || head -c 500 "$tmp" >&2
    echo "Try again later, set OVERPASS_URL to a mirror, or split the query by state." >&2
    rm -f "$tmp"; exit 1
  fi
  if jq -e '.remark // empty' "$tmp" >/dev/null; then
    echo "Overpass returned a partial result: $(jq -r .remark "$tmp")" >&2
    rm -f "$tmp"; exit 1
  fi
  mv "$tmp" "$2"; chmod 644 "$2"
  echo "Saved $(jq '.elements | length' "$2") elements to $2"
}

[ "${SKIP_RINKS:-0}" = 1 ] || fetch "$RINKS_QUERY" "$RAW_JSON"

# Context: named areas that CONTAIN each rink (arena building, sports centre,
# park, school/campus) plus named sports-centre POI nodes within 60 m. Looked
# up by the rink ids we just fetched, in batches, which is far cheaper for
# Overpass than repeating the country-wide search. Relations (multipolygon
# parks, campuses) only need a bounding box.
BATCH="${CONTEXT_BATCH:-250}"
parts=()
total="$(jq '.elements | length' "$RAW_JSON")"
for ((off = 0; off < total; off += BATCH)); do
  set=""
  for t in node way relation; do
    list="$(jq -r --arg t "$t" --argjson o "$off" --argjson n "$BATCH" \
              '[.elements[$o:$o+$n][] | select(.type == $t) | .id] | join(",")' "$RAW_JSON")"
    [ -n "$list" ] && set+="${t/relation/rel}(id:$list);"
  done
  part="$(mktemp)"; parts+=("$part")
  ALLOW_EMPTY=1 fetch "[out:json][timeout:300];
($set)->.rinks;
(node.rinks; node(w.rinks); node(r.rinks); way(r.rinks); node(w);)->.pts;
node.pts->.pts;
.pts is_in->.a;
(
  wr(pivot.a)[\"name\"][\"leisure\"~\"^(sports_centre|sports_hall|stadium|park|recreation_ground|golf_course|resort)$\"];
  wr(pivot.a)[\"name\"][\"building\"];
  wr(pivot.a)[\"name\"][\"amenity\"~\"^(community_centre|school|university|college|events_venue)$\"];
  wr(pivot.a)[\"name\"][\"landuse\"=\"recreation_ground\"];
  node(around.rinks:60)[\"name\"][\"leisure\"~\"^(sports_centre|sports_hall|stadium)$\"];
)->.ctx;
(.ctx; - .rinks;)->.ctx;
(node.ctx; way.ctx;);
out tags geom;
rel.ctx;
out tags bb;" "$part"
  sleep 5   # be polite to the public server
done

jq -c -s '{elements: (map(.elements) | add | unique_by([.type, .id]))}' "${parts[@]}" > "$CONTEXT_JSON"
rm -f "${parts[@]}"
echo "Saved $(jq '.elements | length' "$CONTEXT_JSON") context elements to $CONTEXT_JSON"
