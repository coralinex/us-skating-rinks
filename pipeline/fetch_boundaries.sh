#!/usr/bin/env bash
# Download US Census cartographic boundary files (states, counties, incorporated
# places / CDPs). Used to give every rink a city/county and state, offline.
# Not committed (see .gitignore): ~40 MB, re-downloadable.
#   https://www.census.gov/geographies/mapping-files/time-series/geo/cartographic-boundary.html
source "$(dirname "$0")/env.sh"

base="https://www2.census.gov/geo/tiger/GENZ${CENSUS_YEAR}/shp"
for layer in state county place; do
  f="cb_${CENSUS_YEAR}_us_${layer}_500k.zip"
  dir="$BOUNDARY_DIR/$layer"           # one directory per archive
  mkdir -p "$dir"
  if [ -s "$dir/$f" ]; then
    echo "Have $f"
  else
    echo "Downloading $f ..."
    curl --fail --silent --show-error --retry 3 -o "$dir/$f.part" "$base/$f"
    mv "$dir/$f.part" "$dir/$f"
  fi
done
ls -lh "$BOUNDARY_DIR"/*/*.zip
