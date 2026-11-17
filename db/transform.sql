-- rinks_raw (staging, written by ogr2ogr) -> rinks (clean, deduped).
-- Re-runnable: upserts on (osm_type, osm_id) and removes rows that have
-- disappeared from OSM or been merged away as duplicates.
BEGIN;

CREATE TEMP TABLE stage ON COMMIT DROP AS
WITH parsed AS (
    SELECT osm_type,
           osm_id::bigint  AS osm_id,
           tags::jsonb     AS t,
           ST_MakeValid(geom) AS g
    FROM rinks_raw
    WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
)
SELECT
    osm_type,
    osm_id,
    nullif(btrim(coalesce(t->>'name', t->>'official_name', t->>'alt_name')), '') AS name,
    -- Ways are reduced to a point guaranteed to lie inside the polygon.
    CASE WHEN GeometryType(g) = 'POINT' THEN g
         ELSE ST_PointOnSurface(g) END::geometry(Point, 4326)                  AS geom,
    CASE WHEN GeometryType(g) IN ('POLYGON', 'MULTIPOLYGON')
         THEN ST_Multi(ST_CollectionExtract(g, 3)) END::geometry(MultiPolygon, 4326) AS footprint,
    -- Explicit tags win; a building tag implies indoor; otherwise unknown.
    CASE
        WHEN t->>'indoor'  IN ('yes', 'room', 'area')            THEN true
        WHEN t->>'indoor'  =  'no'                               THEN false
        WHEN t->>'covered' =  'yes'                              THEN true
        WHEN coalesce(t->>'building', 'no') <> 'no'              THEN true
        WHEN t->>'covered' =  'no'                               THEN false
        -- Heuristic: a seasonal rink with no building is an outdoor rink
        -- (flooded park rinks, holiday rinks). Documented in the README.
        WHEN t ? 'seasonal' AND t->>'seasonal' <> 'no'           THEN false
        ELSE NULL
    END                                                          AS indoor,
    CASE
        WHEN t->>'seasonal' = 'no'                               THEN false
        WHEN t ? 'seasonal'                                      THEN true   -- yes / winter / ...
        ELSE NULL
    END                                                          AS seasonal,
    nullif(btrim(t->>'opening_hours'), '')                       AS opening_hours_raw,
    nullif(btrim(coalesce(t->>'website', t->>'contact:website', t->>'url')), '') AS website,
    nullif(btrim(coalesce(t->>'phone', t->>'contact:phone')), '') AS phone,
    nullif(btrim(t->>'addr:housenumber'), '')                    AS addr_housenumber,
    nullif(btrim(t->>'addr:street'), '')                         AS addr_street,
    nullif(btrim(t->>'addr:city'), '')                           AS addr_city,
    nullif(btrim(t->>'addr:state'), '')                          AS addr_state,
    nullif(btrim(t->>'addr:postcode'), '')                       AS addr_postcode,
    t                                                            AS tags
FROM parsed;

CREATE INDEX ON stage USING gist ((geom::geography));
ANALYZE stage;

-- Dedupe ------------------------------------------------------------------
-- Two features are the same rink when either
--   (a) a node sits within 60 m of a way/relation rink and their names do
--       not conflict (a POI node mapped on top of the building outline), or
--   (b) they share a name and are within 150 m of each other
--       (e.g. an ice_rink way inside a sports_centre way).
-- The keeper is the feature with a footprint, then the richest tag set,
-- then the lowest id. Separately-named pads in one complex are kept.
CREATE TEMP TABLE dupes ON COMMIT DROP AS
WITH ranked AS (
    SELECT *,
           -- lower rank = better keeper
           row_number() OVER (ORDER BY (footprint IS NULL),
                                       (SELECT count(*) FROM jsonb_object_keys(tags)) DESC,
                                       osm_type, osm_id) AS rnk
    FROM stage
),
pairs AS (
    SELECT loser.osm_type AS l_type, loser.osm_id AS l_id,
           keeper.osm_type AS k_type, keeper.osm_id AS k_id,
           row_number() OVER (PARTITION BY loser.osm_type, loser.osm_id
                              ORDER BY keeper.rnk) AS pick
    FROM ranked loser
    JOIN ranked keeper
      ON keeper.rnk < loser.rnk
     AND ST_DWithin(keeper.geom::geography, loser.geom::geography, 150)
     AND (
           (lower(keeper.name) = lower(loser.name))
        OR (    loser.osm_type = 'node' AND keeper.osm_type <> 'node'
            AND (loser.name IS NULL OR keeper.name IS NULL)
            AND ST_DWithin(keeper.geom::geography, loser.geom::geography, 60))
         )
)
SELECT l_type, l_id, k_type, k_id FROM pairs WHERE pick = 1;

-- Chains (A loses to B, B loses to C) are resolved by simply dropping every
-- loser; before that, losers donate attributes their direct keeper lacks.
UPDATE stage k SET
    name              = coalesce(k.name, l.name),
    indoor            = coalesce(k.indoor, l.indoor),
    seasonal          = coalesce(k.seasonal, l.seasonal),
    opening_hours_raw = coalesce(k.opening_hours_raw, l.opening_hours_raw),
    website           = coalesce(k.website, l.website),
    phone             = coalesce(k.phone, l.phone),
    addr_housenumber  = coalesce(k.addr_housenumber, l.addr_housenumber),
    addr_street       = coalesce(k.addr_street, l.addr_street),
    addr_city         = coalesce(k.addr_city, l.addr_city),
    addr_state        = coalesce(k.addr_state, l.addr_state),
    addr_postcode     = coalesce(k.addr_postcode, l.addr_postcode)
FROM dupes d
JOIN stage l ON (l.osm_type, l.osm_id) = (d.l_type, d.l_id)
WHERE (k.osm_type, k.osm_id) = (d.k_type, d.k_id);

DELETE FROM stage s USING dupes d
WHERE (s.osm_type, s.osm_id) = (d.l_type, d.l_id);

-- Upsert ------------------------------------------------------------------
INSERT INTO rinks AS r (
    osm_type, osm_id, name, geom, footprint, indoor, seasonal,
    opening_hours_raw, hours_status, website, phone,
    addr_housenumber, addr_street, addr_city, addr_state, addr_postcode,
    tags, updated_at)
SELECT
    osm_type, osm_id, name, geom, footprint, indoor, seasonal,
    opening_hours_raw,
    -- Missing hours are UNKNOWN, never "closed".
    CASE WHEN opening_hours_raw IS NULL THEN 'unknown' ELSE 'known' END,
    website, phone,
    addr_housenumber, addr_street, addr_city, addr_state, addr_postcode,
    tags, now()
FROM stage
ON CONFLICT (osm_type, osm_id) DO UPDATE SET
    name = EXCLUDED.name, geom = EXCLUDED.geom, footprint = EXCLUDED.footprint,
    indoor = EXCLUDED.indoor, seasonal = EXCLUDED.seasonal,
    opening_hours_raw = EXCLUDED.opening_hours_raw, hours_status = EXCLUDED.hours_status,
    website = EXCLUDED.website, phone = EXCLUDED.phone,
    addr_housenumber = EXCLUDED.addr_housenumber, addr_street = EXCLUDED.addr_street,
    addr_city = EXCLUDED.addr_city, addr_state = EXCLUDED.addr_state,
    addr_postcode = EXCLUDED.addr_postcode,
    tags = EXCLUDED.tags, updated_at = EXCLUDED.updated_at;

DELETE FROM rinks r
WHERE NOT EXISTS (SELECT 1 FROM stage s
                  WHERE (s.osm_type, s.osm_id) = (r.osm_type, r.osm_id));

COMMIT;

ANALYZE rinks;

SELECT count(*)                                         AS rinks,
       count(*) FILTER (WHERE name IS NULL)             AS unnamed,
       count(*) FILTER (WHERE indoor)                   AS indoor,
       count(*) FILTER (WHERE indoor = false)           AS outdoor,
       count(*) FILTER (WHERE indoor IS NULL)           AS indoor_unknown,
       count(*) FILTER (WHERE hours_status = 'known')   AS hours_known,
       count(*) FILTER (WHERE footprint IS NOT NULL)    AS with_footprint,
       (SELECT count(*) FROM rinks_raw) - count(*)      AS dropped_as_duplicates
FROM rinks;
