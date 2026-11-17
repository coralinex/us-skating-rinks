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
    ADD COLUMN IF NOT EXISTS name_source text NOT NULL DEFAULT 'osm'
        CHECK (name_source IN ('osm', 'parent', 'none')),     -- where `name` came from
    ADD COLUMN IF NOT EXISTS parent_name text,                -- enclosing facility / park / campus
    ADD COLUMN IF NOT EXISTS parent_osm  text,                -- e.g. "way/123"
    ADD COLUMN IF NOT EXISTS sheets      integer,             -- ice sheets mapped in OSM (null = unknown)
    ADD COLUMN IF NOT EXISTS sheet_names text,                -- e.g. "Rink 1, Rink 2"
    ADD COLUMN IF NOT EXISTS operator    text,
    ADD COLUMN IF NOT EXISTS sports      text,                -- e.g. "ice hockey, curling"
    ADD COLUMN IF NOT EXISTS email       text,
    ADD COLUMN IF NOT EXISTS social      text,                -- Facebook/Instagram URL when no website
    ADD COLUMN IF NOT EXISTS website_source text              -- 'osm' | 'parent'
        CHECK (website_source IN ('osm', 'parent'));

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
     ||   '|north|south|east|west|upper|lower|red|blue|green|gold|silver|white|black|orange|purple|yellow)\s+)*'
     || '(rink|arena|sheet|pad|ice|surface|pond|oval)s?'
     || '(\s*[#-]?\s*([0-9]{1,2}|[a-h]|one|two|three|four|five|six))?$');
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
    left(osm_type, 1) || osm_id::text                        AS id,       -- e.g. "w123"
    coalesce(name, 'Ice rink')                               AS name,
    name_source,                                             -- osm | parent | none
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
    nullif(concat_ws(', ',
        nullif(concat_ws(' ', addr_housenumber, addr_street), ''),
        addr_city,
        nullif(concat_ws(' ', addr_state, addr_postcode), '')
    ), '')                                                   AS address,
    addr_city                                                AS city,
    addr_state                                               AS state,
    geom::geometry(Point, 4326)                              AS geom
FROM rinks;
