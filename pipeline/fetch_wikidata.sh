#!/usr/bin/env bash
# Look up official website (P856) and street address (P6375) on Wikidata for
# every rink, and every surrounding place, that OSM links to a Wikidata item.
# Writes data/raw/wikidata_websites.json (committed, like the Overpass cache).
source "$(dirname "$0")/env.sh"

qids="$(jq -r -s '[.[].elements[] | .tags.wikidata // empty
                   | split(";")[] | gsub("\\s"; "") | select(test("^Q[0-9]+$"))]
                  | unique | map("wd:" + .) | join(" ")' "$RAW_JSON" "$CONTEXT_JSON")"
n="$(wc -w <<<"$qids" | tr -d ' ')"
echo "Looking up $n Wikidata items ..."

read -r -d '' QUERY <<SPARQL || true
SELECT ?item (SAMPLE(?site) AS ?website) (SAMPLE(?addr) AS ?address) WHERE {
  VALUES ?item { $qids }
  OPTIONAL { ?item wdt:P856 ?site . }
  OPTIONAL { ?item wdt:P6375 ?addr . FILTER(LANG(?addr) IN ("en", "mul", "")) }
} GROUP BY ?item
SPARQL

tmp="$(mktemp)"
curl --fail --silent --show-error --retry 3 --retry-delay 10 --max-time 120 \
     -A "ice-rink-map-pipeline/1.0" -H "Accept: application/sparql-results+json" \
     --data-urlencode "query=$QUERY" -o "$tmp" https://query.wikidata.org/sparql
jq '[.results.bindings[]
     | { qid: (.item.value | sub(".*/"; "")),
         website: .website.value,
         address: .address.value }
     | select(.website or .address)]' "$tmp" > "$WIKIDATA_JSON"
rm -f "$tmp"
echo "Saved $(jq length "$WIKIDATA_JSON") items with a website or address to $WIKIDATA_JSON"
