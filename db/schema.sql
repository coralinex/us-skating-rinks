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

CREATE INDEX IF NOT EXISTS rinks_geom_gix      ON rinks USING gist (geom);
-- Geography index so ST_DWithin(geom::geography, ..., metres) is index-assisted.
CREATE INDEX IF NOT EXISTS rinks_geog_gix      ON rinks USING gist ((geom::geography));
CREATE INDEX IF NOT EXISTS rinks_footprint_gix ON rinks USING gist (footprint);

-- The tile contract. Both delivery modes read THIS view, so property names
-- are identical whether tiles come from tippecanoe/PMTiles or from Martin.
-- Only flat, precomputed columns: frontend filters depend on nothing else.
CREATE OR REPLACE VIEW rinks_tiles AS
SELECT
    left(osm_type, 1) || osm_id::text                        AS id,       -- e.g. "w123"
    coalesce(name, 'Ice rink')                               AS name,
    CASE WHEN indoor IS NULL THEN 'unknown'
         WHEN indoor THEN 'yes' ELSE 'no' END                AS indoor,
    CASE WHEN seasonal IS NULL THEN 'unknown'
         WHEN seasonal THEN 'yes' ELSE 'no' END              AS seasonal,
    hours_status,
    opening_hours_raw                                        AS opening_hours,
    website,
    phone,
    nullif(concat_ws(', ',
        nullif(concat_ws(' ', addr_housenumber, addr_street), ''),
        addr_city,
        nullif(concat_ws(' ', addr_state, addr_postcode), '')
    ), '')                                                   AS address,
    addr_state                                               AS state,
    geom::geometry(Point, 4326)                              AS geom
FROM rinks;
