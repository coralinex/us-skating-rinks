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
pipeline/fetch_overpass.sh   # optional: data/raw/*.json is cached in the repo (slow: ~10 batched queries)
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

**GitHub Pages** (set up in `.github/workflows/deploy.yml`):

1. Repo **Settings → Pages → Build and deployment → Source: GitHub Actions**
   (one time). Pages needs a public repo, or a paid GitHub plan for a private one.
2. Push to `main`. Any change under `web/` rebuilds and publishes the site at
   `https://<user>.github.io/<repo>/`. To publish new data, re-run the pipeline
   locally and commit `web/public/rinks.pmtiles`.

The build uses relative asset paths (`web/vite.config.ts`), so `web/dist/` also
works on any other static host (Cloudflare Pages, Netlify, S3, …):
`cd web && npm run build` and upload `web/dist/`. The host must support HTTP
range requests for `rinks.pmtiles` (GitHub Pages, Cloudflare and Netlify do).
To host the tiles separately, set `VITE_TILE_SOURCE=pmtiles://https://…/rinks.pmtiles`
(as a repository variable for the workflow). See `web/.env.example`.

Before sending real traffic: drive time uses the FOSSGIS Valhalla demo server
and place search uses public Nominatim. Both are fair-use services for light
traffic; switch to OpenRouteService (`VITE_ORS_API_KEY`) or your own instances
if the site gets busy.

## Data

Source: OpenStreetMap via Overpass, as nodes, ways and relations:

- `leisure=ice_rink`, and `sport=ice_skating` on `leisure=sports_centre|pitch`;
- ice venues mapped only as a generic sports centre: `leisure=sports_centre|sports_hall`
  with `sport` containing skating/hockey/curling, or with "Ice" in the name.
  Some real rinks exist only this way (e.g. Icetown Riverside is
  `leisure=sports_centre` + `sport=skating`). The same tags match roller rinks,
  so `rink_is_ice_venue()` in `db/schema.sql` keeps only ice venues.

A second query fetches the **named places that contain each rink** (arena
buildings, sports centres, parks, schools/campuses), cached as
`data/raw/context_overpass.json`. It is incremental: only rinks not looked up
before are queried (`CONTEXT_FULL=1` rebuilds it).

Current snapshot: **2,567 OSM elements → 2,206 rinks** (213 roller rinks and
skate parks filtered out, the rest merged as duplicates or sheets of one venue),
plus 70 curated holiday and winter-season rinks not in OSM.

| | count |
|---|---|
| Name from the rink's own OSM tags | 1,300 |
| Name inherited from the surrounding place | 614 |
| Still unnamed (shown as "Ice rink") | 279 |
| Has a website | 764 (206 inherited from the surrounding place) |
| Has an address (at least street or city) | 1,101 |
| Indoor / outdoor / not tagged | 1,049 / 546 / 681 |
| Has `opening_hours` | **85** (4%) |

### How names and contact details are derived

A sports complex that contains a separately named, mapped rink is treated as a
container rather than a rink of its own: "Sidney J. Watson Arena" is shown, the
"Pickard Field Athletic Complex" around it is not (its details are still
inherited). Sheets named after their venue ("Olympia Ice Center Rink 3") count
as sheets of that venue.

OSM often maps the ice sheet itself as "Rink 1", "Blue Rink" or with no name,
and puts the real name, website and address on the building or park around it.
`db/transform.sql` therefore finds each rink's *parent* (smallest named area
containing it, or a sports-centre POI within 60 m) and:

- **Generic or missing name + venue parent** (sports centre, arena, anything
  ice-related): the rink takes the venue's name, and all sheets of one venue
  collapse into a single rink with `sheets` and `sheet_names`
  ("Rink 1, Rink 2, Rink 3").
- **Generic or missing name + other parent** (park, school, generic building):
  "Ice rink at Lions Park" / "Bryant Park – The Rink".
- **Website, phone, email, operator, address** are inherited when the rink has
  none (`website_source = 'parent'`; the info card names the source).
- A rink inside a building outline is marked indoor.
- `rink_name_is_generic()` in `db/schema.sql` defines "generic"; 12 such rinks
  have no named place around them and keep their OSM name.

The info card always has a Website row: the rink's site, else its Facebook/
Instagram page, else "Not listed · Search the web".

### Holiday pop-up rinks (curated source)

Holiday rinks are mostly **not in OpenStreetMap**: they exist for 6–10 weeks
on a plaza, pier or parking lot. Of 13 well-known Southern California holiday
rinks, OSM had one. They therefore come from a second, checked-in source:

- `data/holiday_rinks.csv` — one row per rink: name, venue, address,
  coordinates (venue-level), `season_start` / `season_end`, `opening_hours`
  (OSM syntax, only when the rink publishes a regular schedule), website,
  `source_url`, `verified_season` and `confidence`.
- `load.sh` copies it into `rinks_curated_raw`; `transform.sql` merges it into
  `rinks`. A curated rink within 250 m of an outdoor OSM rink enriches that row
  (`source = 'osm+curated'`); the rest are inserted with `osm_type = 'curated'`.
- Every rink gets a `rink_type`: `holiday` (all curated rinks, plus OSM
  seasonal outdoor rinks south of 35°N or with a holiday-style name or
  Nov–Jan opening dates), `seasonal` (winter only), `year_round` (indoor or
  `seasonal=no`) or `unknown`.

In the app: a **Type** filter, an **Only rinks in season today** toggle, a pink
ring on holiday markers, and season dates on the card. A rink outside its
published season is treated as closed by the "Open now / Open at" filter.

Current coverage: **83 rinks in 23 states**, researched for the 2026–27 season
by searching each major metro and checking official pages where one exists.
Each row has a `confidence`: `high` (dates from the venue or organiser),
`medium` (one or more local guides), `low` (conflicting, truncated or
directory-only information). 77 rows have season dates; the rest are known to
operate but had not published dates when checked. Coordinates are venue-level
(geocoded), not the rink footprint.

This is **not complete**: there is no national registry of pop-up rinks, and
small-town or one-off rinks are missed. Metros searched without a confirmed
2026–27 rink include Portland, Minneapolis, Milwaukee, Boston, Miami and
Jacksonville. To add rinks, append rows to the CSV and re-run `load.sh` and
`build_tiles.sh`. Dates change every year: re-verify each row per season and
bump `verified_season`.

Curated rinks whose season runs past mid-February (Rockefeller Center, Crown
Center Ice Terrace, …) are typed `seasonal`, not `holiday`.

### Caveats

- **Hours are mostly missing.** Only ~3% of rinks have `opening_hours`. Missing
  hours are `hours_status = 'unknown'`, never "closed": with a time filter on,
  those rinks stay visible as hollow markers unless you untick "Also show rinks
  with hours not listed", and popups say "Hours not listed".
- **Hours are evaluated in the rink's local time**, not the viewer's
  (`tz-lookup` + `opening_hours`).
- **Outdoor is partly inferred.** OSM rarely tags `indoor=no`; a rink tagged
  `seasonal=*` that is not in a building is treated as outdoor (`db/transform.sql`).
  Everything else without an explicit tag is "not tagged".
- **Seasonal outdoor rinks** (park and holiday rinks) are patchy in OSM.
- **`ice_rink` includes hockey-only rinks.** Nothing here promises public skating.
- **Inherited names can be wrong** where OSM's enclosing area is not really
  the rink's venue (e.g. a rink in a mall takes "Ice rink at <mall>"). The card
  says "Named after the place it is in" and links to the OSM object to fix it.
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
- PMTiles: all points present at zoom 0 and zoom 14.
- Radius filter in the browser vs. SQL at Minneapolis (−93.265, 44.978), 10 mi: browser count = SQL count.
- 30-minute drive-time polygon around Minneapolis is plausible (231 rinks inside).
- Same frontend against Martin with only `VITE_TILE_SOURCE` changed: same rinks.

## Not done yet

- README screenshots.
- Footprint layer at high zoom.
- Server-side filtering (Postgres function source) and self-hosted routing.
