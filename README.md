# us-skating-rinks

Every ice rink in the US from OpenStreetMap on a zoomable vector-tile map, with
filters for indoor/outdoor, opening hours, straight-line distance and drive time.

Built **static first** (one PMTiles file on any static host), structured so that
switching to a **live PostGIS backend** is a one-line config change.

## Architecture

```
                 ┌──────────────── pipeline/ ────────────────┐
 OpenStreetMap   │ fetch_overpass.sh   load.sh               │
 (Overpass API) ─┼─► data/raw/*.json ─► ogr2ogr ─► rinks_raw │
                 │                         db/transform.sql  │
                 └───────────────────────────────┬───────────┘
                                                 ▼
                                   PostGIS  ── table `rinks`   (source of truth)
                                            └─ view  `rinks_tiles` (tile contract)
                                                 │
                 ┌───────────────────────────────┴──────────────────────────────┐
     STATIC      ▼                                                 REALTIME     ▼
 build_tiles.sh: GeoJSONSeq ─► tippecanoe                                    Martin
        web/public/rinks.pmtiles                                /rinks/{z}/{x}/{y}
                 │                                                              │
                 └──────────────► TILE_SOURCE (web/src/config.ts) ◄─────────────┘
                                                 ▼
                    MapLibre GL JS · source-layer "rinks" · same properties
                    filters.ts (expressions) · hours.ts · isochrone.ts
```

What keeps the static → realtime swap a config change:

1. **One config value.** `VITE_TILE_SOURCE` (`web/src/config.ts`) is the only
   difference between modes.
2. **One tile contract.** Both the tippecanoe export and Martin read the
   `rinks_tiles` view, so layer name (`rinks`) and property names are identical.
3. **Filters use only tile properties + geometry** (`id`, `indoor`,
   `hours_status`, `opening_hours`), via MapLibre expressions (`in`, `distance`,
   `within`).
4. **Drive time sits behind `getIsochrone(lngLat, minutes)`** in
   `web/src/isochrone.ts`.

## Run it

Requirements: PostgreSQL + PostGIS, GDAL (`ogr2ogr`), `tippecanoe`, `jq`, `curl`, Node 20+.

```bash
# 1. Database — either Docker…
docker compose up -d db
# …or, without Docker (Homebrew: brew install postgresql@17 postgis tippecanoe node):
pipeline/local_db.sh start
export DATABASE_URL=postgresql://localhost:54329/rinks

# 2. Pipeline
pipeline/fetch_overpass.sh   # optional: data/raw/rinks_overpass.json is cached in the repo
pipeline/load.sh             # schema.sql → ogr2ogr → transform.sql
pipeline/build_tiles.sh      # → web/public/rinks.pmtiles

# 3. Web app
cd web && npm install && npm run dev
```

`web/public/rinks.pmtiles` is checked in, so step 3 works on its own.

### Realtime mode

```bash
DATABASE_URL=postgresql://localhost:54329/rinks martin --config martin/config.yaml
cd web && VITE_TILE_SOURCE='http://localhost:3000/rinks/{z}/{x}/{y}' npm run dev
```

(or uncomment the `martin` service in `docker-compose.yml`). No other frontend
change. For freshness, cron `fetch_overpass.sh && load.sh` — `transform.sql`
upserts on `(osm_type, osm_id)` and removes rinks deleted from OSM.

### Deploy (static)

`cd web && npm run build`, then upload `web/dist/` to any static host. To host
the tiles separately (Cloudflare R2, Azure Blob, …) set
`VITE_TILE_SOURCE=pmtiles://https://…/rinks.pmtiles`; the host must support
HTTP range requests and CORS. See `web/.env.example` for all settings.

## Data

Source: OpenStreetMap via Overpass — `leisure=ice_rink`, plus
`sport=ice_skating` on `leisure=sports_centre|pitch`, as nodes, ways and
relations. Current snapshot: **2,084 OSM elements → 2,061 rinks** after dedupe.

| | count |
|---|---|
| Indoor (`indoor`/`covered`/`building` tag) | 730 |
| Outdoor | 512 |
| Indoor/outdoor not tagged | 819 |
| Has `opening_hours` | **62** (3%) |
| Unnamed (shown as "Ice rink") | 936 |

### Caveats

- **Hours are mostly missing.** Only ~3% of rinks have `opening_hours`. Missing
  hours are `hours_status = 'unknown'`, never "closed": with a time filter on,
  those rinks stay visible as hollow markers unless you untick "Also show rinks
  with hours not listed", and popups say "Hours not listed".
- **Hours are evaluated in the rink's local time**, not the viewer's
  (`tz-lookup` + `opening_hours`).
- **Outdoor is partly inferred.** OSM rarely tags `indoor=no`; a rink tagged
  `seasonal=*` with no `building` is treated as outdoor (`db/transform.sql`).
  Everything else without an explicit tag is "not tagged".
- **Seasonal outdoor rinks** (park and holiday rinks) are patchy in OSM.
- **`ice_rink` includes hockey-only rinks.** Nothing here promises public skating.
- **Dedupe** (`ST_DWithin` on geography): a node within 60 m of a rink
  outline (when at least one of the two is unnamed), or two same-named
  features within 150 m, collapse into one; the survivor inherits missing name/hours/contact fields. Separately
  named pads in one complex are kept.
- Relations and open ways are placed at their bounding-box centre; closed ways
  use `ST_PointOnSurface` and keep a `footprint` polygon (not yet drawn).

### Third-party services called from the browser

| Service | Used for | Notes |
|---|---|---|
| OpenFreeMap | Basemap | No key |
| FOSSGIS Valhalla demo server | Drive-time isochrones | No key, fair-use only; set `VITE_ORS_API_KEY` to use OpenRouteService, or `VITE_VALHALLA_URL` for your own |
| Nominatim | Place search (on submit only) | Fair-use; swap `GEOCODER_URL` for production traffic |

Isochrones are cached per point + minutes. The pin location is sent to the
routing service; search text is sent to Nominatim.

## Checks run

- `SELECT postgis_version()` → 3.6; 0 null/invalid geometries.
- `EXPLAIN` on `ST_DWithin(geom::geography, …)` uses `rinks_geog_gix`.
- PMTiles: all 2,061 points present at zoom 0 and zoom 14.
- Radius filter in the browser vs. SQL at Minneapolis (−93.265, 44.978), 10 mi: 67 = 67.
- 30-minute drive-time polygon around Minneapolis is plausible (231 rinks inside).
- Same frontend against Martin with only `VITE_TILE_SOURCE` changed: same rinks.

## Not done yet

- Hosting / public deploy, README screenshots.
- Footprint layer at high zoom.
- Server-side filtering (Postgres function source) and self-hosted routing.
