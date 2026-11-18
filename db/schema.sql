-- Schema for the ice rink map. Idempotent: safe to re-apply.
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS rinks (
    osm_type          text        NOT NULL CHECK (osm_type IN ('node', 'way', 'relation')),
    osm_id            bigint      NOT NULL,
    name              text,                                   -- null => UI labels it "Ice rink"
    geom              geometry(Point, 4326) NOT NULL,
    footprint         geometry(MultiPolygon, 4326),           -- only for closed ways
    indoor            boolean,                                -- null => unknown
    seasonal          boolean,                                -- null => unknown
    opening_hours_raw text,                                   -- OSM string as-is
    hours_status      text        NOT NULL DEFAULT 'unknown'
                                  CHECK (hours_status IN ('known', 'unknown')),
    website           text,
    phone             text,
    addr_housenumber  text,
    addr_street       text,
    addr_city         text,
    addr_state        text,
    addr_postcode     text,
    tags              jsonb       NOT NULL DEFAULT '{}'::jsonb,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (osm_type, osm_id)
);

-- Added after v1. `ADD COLUMN IF NOT EXISTS` keeps existing databases working.
ALTER TABLE rinks
    ADD COLUMN IF NOT EXISTS name_source text NOT NULL DEFAULT 'osm',  -- where `name` came from
    ADD COLUMN IF NOT EXISTS parent_name text,                -- enclosing facility / park / campus
    ADD COLUMN IF NOT EXISTS parent_osm  text,                -- e.g. "way/123"
    ADD COLUMN IF NOT EXISTS sheets      integer,             -- ice sheets mapped in OSM (null = unknown)
    ADD COLUMN IF NOT EXISTS sheet_names text,                -- e.g. "Rink 1, Rink 2"
    ADD COLUMN IF NOT EXISTS operator    text,
    ADD COLUMN IF NOT EXISTS sports      text,                -- e.g. "ice hockey, curling"
    ADD COLUMN IF NOT EXISTS email       text,
    ADD COLUMN IF NOT EXISTS social      text,                -- Facebook/Instagram URL when no website
    ADD COLUMN IF NOT EXISTS website_source text;             -- 'osm' | 'parent' | 'curated' | 'wikidata'

-- Curated (non-OSM) rinks and rink type. Holiday pop-up rinks are mostly
-- absent from OSM, so they come from data/holiday_rinks.csv and are stored
-- with osm_type = 'curated' and a stable id derived from the CSV slug.
ALTER TABLE rinks
    ADD COLUMN IF NOT EXISTS source          text NOT NULL DEFAULT 'osm',  -- osm | curated | osm+curated
    ADD COLUMN IF NOT EXISTS rink_type       text NOT NULL DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS venue           text,      -- where a pop-up is set up
    ADD COLUMN IF NOT EXISTS season_start    date,      -- this season's first / last day,
    ADD COLUMN IF NOT EXISTS season_end      date,      --   when published
    ADD COLUMN IF NOT EXISTS verified_season text,      -- e.g. '2026-27'
    ADD COLUMN IF NOT EXISTS source_url      text,
    ADD COLUMN IF NOT EXISTS confidence      text,      -- high | medium | low (curated rows)
    ADD COLUMN IF NOT EXISTS notes           text;

ALTER TABLE rinks DROP CONSTRAINT IF EXISTS rinks_osm_type_check;
ALTER TABLE rinks ADD  CONSTRAINT rinks_osm_type_check
    CHECK (osm_type IN ('node', 'way', 'relation', 'curated'));
ALTER TABLE rinks DROP CONSTRAINT IF EXISTS rinks_name_source_check;
ALTER TABLE rinks ADD  CONSTRAINT rinks_name_source_check
    CHECK (name_source IN ('osm', 'parent', 'curated', 'none'));
ALTER TABLE rinks DROP CONSTRAINT IF EXISTS rinks_website_source_check;
ALTER TABLE rinks ADD  CONSTRAINT rinks_website_source_check
    CHECK (website_source IN ('osm', 'parent', 'curated', 'wikidata'));
ALTER TABLE rinks DROP CONSTRAINT IF EXISTS rinks_rink_type_check;
ALTER TABLE rinks ADD  CONSTRAINT rinks_rink_type_check
    CHECK (rink_type IN ('year_round', 'seasonal', 'holiday', 'unknown'));
ALTER TABLE rinks DROP CONSTRAINT IF EXISTS rinks_source_check;
ALTER TABLE rinks ADD  CONSTRAINT rinks_source_check
    CHECK (source IN ('osm', 'curated', 'osm+curated'));

-- Staging for data/holiday_rinks.csv (all text; typed in transform.sql).
CREATE TABLE IF NOT EXISTS rinks_curated_raw (
    slug text PRIMARY KEY, name text, venue text, address text, city text, state text,
    lat text, lon text, indoor text, season_start text, season_end text,
    opening_hours text, website text, phone text, source_url text,
    verified_season text, confidence text, notes text
);

-- Enrichment beyond OSM tags (phase 1): Census boundaries and Wikidata.
ALTER TABLE rinks
    ADD COLUMN IF NOT EXISTS place_name     text,   -- Census incorporated place / CDP containing the rink
    ADD COLUMN IF NOT EXISTS county_name    text,   -- e.g. "Riverside County"
    ADD COLUMN IF NOT EXISTS state_code     text,   -- USPS code, e.g. "CA"
    ADD COLUMN IF NOT EXISTS addr_full      text,   -- one-line address when OSM has no street
    ADD COLUMN IF NOT EXISTS address_source text;   -- source of addr_full: 'wikidata'
ALTER TABLE rinks DROP CONSTRAINT IF EXISTS rinks_address_source_check;
ALTER TABLE rinks ADD  CONSTRAINT rinks_address_source_check
    CHECK (address_source IN ('wikidata'));

-- data/raw/wikidata_websites.json, written by pipeline/fetch_wikidata.sh.
CREATE TABLE IF NOT EXISTS rinks_wikidata_raw (
    qid text PRIMARY KEY, website text, address text
);

-- First valid QID in an OSM wikidata tag ("Q123" or "Q123;Q456").
CREATE OR REPLACE FUNCTION rink_first_qid(tag text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT substring(tag FROM 'Q[0-9]+');
$$;

CREATE INDEX IF NOT EXISTS rinks_geom_gix      ON rinks USING gist (geom);
-- Geography index so ST_DWithin(geom::geography, ..., metres) is index-assisted.
CREATE INDEX IF NOT EXISTS rinks_geog_gix      ON rinks USING gist ((geom::geography));
CREATE INDEX IF NOT EXISTS rinks_footprint_gix ON rinks USING gist (footprint);

-- A name that only identifies a sheet within a facility ("Rink 1", "Blue
-- Rink", "Ice Arena", "The Rink") and says nothing about which facility.
CREATE OR REPLACE FUNCTION rink_name_is_generic(name text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT name IS NOT NULL AND btrim(name) ~* (
        '^(the\s+)?'
     || '((ice|skating|hockey|curling|figure|outdoor|indoor|public|community|main|practice|studio|olympic|nhl'
     ||   '|north|south|east|west|upper|lower|red|blue|green|gold|silver|white|black|orange|purple|yellow'
     ||   '|gray|grey|pink|teal|navy|maroon|crimson|bronze|platinum)\s+)*'
     || '(rink|arena|sheet|pad|ice|surface|pond|oval)s?'
     || '(\s*[#-]?\s*([0-9]{1,2}|[a-h]|one|two|three|four|five|six))?$');
$$;

-- Is `name` just a sheet of the venue `parent`? True when it is generic on
-- its own ("Rink 2") or is the venue's name plus a generic suffix
-- ("Olympia Ice Center Rink 3" inside "Olympia Ice Center").
CREATE OR REPLACE FUNCTION rink_name_is_sheet_of(name text, parent text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT rink_name_is_generic(name)
        OR (parent IS NOT NULL AND name IS NOT NULL
            AND length(name) > length(parent)
            AND lower(left(name, length(parent))) = lower(parent)
            AND rink_name_is_generic(btrim(substr(name, length(parent) + 1), ' -–—:,()')));
$$;

-- Is this OSM feature an ICE venue? The fetch query also pulls in generic
-- sports centres (leisure=sports_centre + sport=skating|hockey, or "Ice" in
-- the name) because some ice rinks are only mapped that way, e.g. Icetown
-- Riverside. Those tags also match roller rinks, which this filters out.
CREATE OR REPLACE FUNCTION rink_is_ice_venue(t jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    WITH f AS (
        SELECT coalesce(t->>'name', '') AS name,
               ARRAY(SELECT lower(btrim(x)) FROM regexp_split_to_table(coalesce(t->>'sport', ''), ';') x) AS sports
    ), r AS (
        SELECT *,
               name ~* '\m(roller|rollerskat\w*|skate ?(land|station|park|world|zone|city|plex|board)\w*|skateland|kate''s skate)\M'
                 OR sports && ARRAY['roller_skating', 'roller_hockey', 'skateboard', 'inline_skating']  AS roller
        FROM f
    )
    SELECT CASE
        WHEN t->>'leisure' = 'ice_rink'                                       THEN true
        WHEN roller AND NOT sports && ARRAY['ice_skating', 'ice_hockey']      THEN false
        -- unambiguous ice sports
        WHEN sports && ARRAY['ice_skating', 'ice_hockey', 'curling', 'figure_skating',
                             'speed_skating', 'ice_stock']                    THEN true
        -- "skating" / "hockey" can be roller, dek or field hockey: needs a name,
        -- and one that is not a court or field unless it says "ice"
        WHEN sports && ARRAY['skating', 'hockey'] AND name <> ''
             AND (name ~* '\m(ice|icetown|iceplex|icehouse)\M'
                  OR name !~* '\m(court|courts|field|fields|gym|gymnasium)\M')  THEN true
        -- no ice sport tagged: trust an explicit "Ice" in the name
        WHEN name ~* '\m(ice|icetown|iceplex|icehouse)\M'                    THEN true
        ELSE false
    END
    FROM r;
$$;

-- http(s) URL or null. Adds a scheme to bare domains, rejects junk.
CREATE OR REPLACE FUNCTION rink_clean_url(raw text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN u ~* '^https?://[^\s/]+\.[^\s/]+' THEN u
        WHEN u ~* '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}(/\S*)?$' THEN 'https://' || u
    END
    FROM (SELECT btrim(split_part(raw, ';', 1)) AS u) s;
$$;

-- The tile contract. Both delivery modes read THIS view, so property names
-- are identical whether tiles come from tippecanoe/PMTiles or from Martin.
-- Only flat, precomputed columns: frontend filters depend on nothing else.
DROP VIEW IF EXISTS rinks_tiles;
CREATE VIEW rinks_tiles AS
SELECT
    left(osm_type, 1) || osm_id::text                        AS id,       -- e.g. "w123"; "c…" = curated
    coalesce(name, 'Ice rink')                               AS name,
    name_source,                                             -- osm | parent | curated | none
    rink_type,                                               -- year_round | seasonal | holiday | unknown
    venue,
    to_char(season_start, 'YYYY-MM-DD')                      AS season_start,
    to_char(season_end,   'YYYY-MM-DD')                      AS season_end,
    verified_season,
    source,                                                  -- osm | curated | osm+curated
    source_url,
    confidence,
    notes,
    parent_name,
    CASE WHEN indoor IS NULL THEN 'unknown'
         WHEN indoor THEN 'yes' ELSE 'no' END                AS indoor,
    CASE WHEN seasonal IS NULL THEN 'unknown'
         WHEN seasonal THEN 'yes' ELSE 'no' END              AS seasonal,
    hours_status,
    opening_hours_raw                                        AS opening_hours,
    website,
    website_source,
    social,
    phone,
    email,
    operator,
    sports,
    sheets,
    sheet_names,
    -- Street address: OSM's own when it has a street, else Wikidata's.
    -- A city/state alone is not an address; it goes in `locality`.
    -- Missing city / state are filled from the Census place the rink is in.
    CASE WHEN addr_street IS NOT NULL OR addr_housenumber IS NOT NULL THEN
        concat_ws(', ',
            nullif(concat_ws(' ', addr_housenumber, addr_street), ''),
            coalesce(addr_city, place_name),
            nullif(concat_ws(' ', coalesce(addr_state, state_code), addr_postcode), ''))
         WHEN addr_full IS NOT NULL AND addr_full !~ '\m[A-Z]{2}\M' THEN
        -- e.g. "1 American Dream Way, 07073" -> add "East Rutherford, NJ"
        concat_ws(', ', addr_full, coalesce(place_name, county_name), state_code)
         ELSE addr_full END                                  AS address,
    CASE WHEN addr_street IS NOT NULL OR addr_housenumber IS NOT NULL THEN NULL
         ELSE address_source END                             AS address_source,
    -- "Riverside, CA" / "Riverside County, CA": where the rink is, for every
    -- rink (Census boundaries), used when there is no street address.
    nullif(concat_ws(', ', coalesce(addr_city, place_name, county_name),
                           coalesce(state_code, addr_state)), '') AS locality,
    coalesce(addr_city, place_name)                          AS city,
    coalesce(state_code, addr_state)                         AS state,
    geom::geometry(Point, 4326)                              AS geom
FROM rinks;
