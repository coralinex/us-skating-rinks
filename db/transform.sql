-- rinks_raw + rinks_context_raw (staging, written by ogr2ogr) -> rinks.
-- Re-runnable: upserts on (osm_type, osm_id) and removes rows that have
-- disappeared from OSM or been merged away as duplicates.
--
--   1. Parse tags into columns.
--   2. Find each rink's "parent": the named facility / park / campus that
--      contains it. OSM often maps the ice sheet as "Rink 1" (or unnamed) and
--      puts the real name, website and address on the surrounding building.
--   3. Inherit name and contact details from the parent.
--   4. Collapse the sheets of one facility into a single rink with a count.
--   5. Dedupe what is left, then upsert.
BEGIN;

-- 1. Parse -------------------------------------------------------------------
CREATE TEMP TABLE stage ON COMMIT DROP AS
WITH parsed AS (
    SELECT osm_type,
           osm_id::bigint  AS osm_id,
           tags::jsonb     AS t,
           ST_MakeValid(geom) AS g
    FROM rinks_raw
    WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
      AND rink_is_ice_venue(tags::jsonb)        -- drops roller rinks, skate parks
)
SELECT
    osm_type,
    osm_id,
    nullif(btrim(coalesce(t->>'name', t->>'official_name', t->>'name:en',
                          t->>'alt_name', t->>'short_name')), '')              AS name,
    -- Ways are reduced to a point guaranteed to lie inside the polygon.
    CASE WHEN GeometryType(g) = 'POINT' THEN g
         ELSE ST_PointOnSurface(g) END::geometry(Point, 4326)                  AS geom,
    CASE WHEN GeometryType(g) IN ('POLYGON', 'MULTIPOLYGON')
         THEN ST_Multi(ST_CollectionExtract(g, 3)) END::geometry(MultiPolygon, 4326) AS footprint,
    -- Explicit tags only here; inferred values are filled in after step 3.
    CASE
        WHEN t->>'indoor'  IN ('yes', 'room', 'area')            THEN true
        WHEN t->>'indoor'  =  'no'                               THEN false
        WHEN t->>'covered' =  'yes'                              THEN true
        WHEN coalesce(t->>'building', 'no') <> 'no'              THEN true
        WHEN t->>'covered' =  'no'                               THEN false
        ELSE NULL
    END                                                          AS indoor,
    CASE
        WHEN t->>'seasonal' = 'no'                               THEN false
        WHEN t ? 'seasonal'                                      THEN true   -- yes / winter / ...
        ELSE NULL
    END                                                          AS seasonal,
    nullif(btrim(t->>'opening_hours'), '')                       AS opening_hours_raw,
    coalesce(rink_clean_url(t->>'website'), rink_clean_url(t->>'contact:website'),
             rink_clean_url(t->>'url'), rink_clean_url(t->>'website:alternate'),
             rink_clean_url(t->>'brand:website'), rink_clean_url(t->>'operator:website')) AS website,
    coalesce(
        (SELECT CASE WHEN v ~* '^https?://' THEN v
                     WHEN v ~ '^@?[A-Za-z0-9._-]+$' THEN 'https://www.facebook.com/' || ltrim(v, '@') END
         FROM (SELECT btrim(coalesce(t->>'contact:facebook', t->>'facebook', t->>'brand:facebook')) AS v) f),
        (SELECT CASE WHEN v ~* '^https?://' THEN v
                     WHEN v ~ '^@?[A-Za-z0-9._]+$' THEN 'https://www.instagram.com/' || ltrim(v, '@') END
         FROM (SELECT btrim(t->>'contact:instagram') AS v) i))   AS social,
    nullif(btrim(coalesce(t->>'phone', t->>'contact:phone')), '') AS phone,
    nullif(btrim(coalesce(t->>'email', t->>'contact:email')), '') AS email,
    nullif(btrim(t->>'operator'), '')                            AS operator,
    (SELECT string_agg(DISTINCT replace(btrim(x), '_', ' '), ', ')
     FROM regexp_split_to_table(t->>'sport', ';') x WHERE btrim(x) <> '') AS sports,
    nullif(btrim(t->>'addr:housenumber'), '')                    AS addr_housenumber,
    nullif(btrim(t->>'addr:street'), '')                         AS addr_street,
    nullif(btrim(t->>'addr:city'), '')                           AS addr_city,
    nullif(btrim(t->>'addr:state'), '')                          AS addr_state,
    nullif(btrim(t->>'addr:postcode'), '')                       AS addr_postcode,
    t                                                            AS tags,
    -- Filled in by the steps below.
    'osm'::text         AS name_source,
    NULL::text          AS website_source,
    NULL::text          AS parent_name,
    NULL::text          AS parent_osm,
    NULL::text          AS group_key,      -- facility this sheet collapses into
    NULL::integer       AS sheets,
    NULL::text          AS sheet_names,
    'osm'::text         AS source,
    NULL::text          AS venue,
    NULL::date          AS season_start,
    NULL::date          AS season_end,
    NULL::text          AS verified_season,
    NULL::text          AS source_url,
    NULL::text          AS confidence,
    NULL::text          AS notes,
    'unknown'::text     AS rink_type
FROM parsed;

UPDATE stage SET website_source = 'osm' WHERE website IS NOT NULL;
CREATE INDEX ON stage USING gist (geom);
CREATE INDEX ON stage USING gist ((geom::geography));
ANALYZE stage;

-- 2. Parent candidates ---------------------------------------------------------
-- Named context features, plus rinks that are themselves a properly named
-- outline (e.g. a sports_centre tagged sport=ice_skating containing "Rink 1").
CREATE TEMP TABLE cand ON COMMIT DROP AS
WITH c AS (
    SELECT osm_type, osm_id::bigint AS osm_id, false AS is_rink,
           nullif(btrim(tags::jsonb->>'name'), '') AS name,
           tags::jsonb AS t, ST_MakeValid(geom) AS g
    FROM rinks_context_raw
    WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
    UNION ALL
    SELECT osm_type, osm_id, true, name, tags, footprint
    FROM stage
    WHERE footprint IS NOT NULL
)
SELECT c.*,
       GeometryType(g) IN ('POLYGON', 'MULTIPOLYGON')                     AS is_poly,
       CASE WHEN GeometryType(g) IN ('POLYGON', 'MULTIPOLYGON')
            THEN ST_Area(g::geography) ELSE 0 END                         AS area,
       coalesce(t->>'building', 'no') <> 'no'                             AS is_building,
       -- "Facility": the place *is* the rink venue, so its name can stand in
       -- for the rink's. Parks, schools and generic buildings are not; their
       -- rinks are labelled "Ice rink at <name>" instead.
       (   is_rink
        OR t->>'leisure'  IN ('sports_centre', 'sports_hall', 'stadium')
        OR t->>'building' IN ('sports_centre', 'sports_hall', 'stadium', 'ice_rink')
        OR t->>'sport' ~ '(ice_hockey|ice_skating|curling|ice_stock|skating|hockey)'
        OR name ~* '\m(ice|rink|rinks|arena|skat\w*|hockey|curling|iceplex|sportsplex|icehouse|coliseum)\M'
       )                                                                  AS facility
FROM c
WHERE name IS NOT NULL AND NOT rink_name_is_generic(name);

CREATE INDEX ON cand USING gist (g);
ANALYZE cand;

CREATE TEMP TABLE parent ON COMMIT DROP AS
SELECT DISTINCT ON (s.osm_type, s.osm_id)
       s.osm_type, s.osm_id,
       c.osm_type AS p_type, c.osm_id AS p_id, c.name AS p_name, c.t AS p_t,
       c.facility, c.is_poly, c.is_building
FROM stage s
JOIN cand c
  ON (c.osm_type, c.osm_id) <> (s.osm_type, s.osm_id)
 AND (
       -- an area that contains the rink and is clearly bigger than it
       (    c.is_poly AND ST_Covers(c.g, s.geom)
        AND c.area < 2e7                                           -- ignore huge areas (> 20 km²)
        AND c.area > 1.2 * coalesce(ST_Area(s.footprint::geography), 0))
       -- or a sports-centre POI node right next to it
    OR (    NOT c.is_poly AND c.facility AND NOT c.is_rink
        AND ST_DWithin(c.g::geography, s.geom::geography, 60))
     )
ORDER BY s.osm_type, s.osm_id,
         CASE WHEN c.is_poly AND c.facility THEN 1      -- venue outline around the rink
              WHEN NOT c.is_poly            THEN 2      -- venue POI beside the rink
              ELSE 3 END,                               -- park / campus / other building
         c.area,                                        -- smallest enclosing area wins
         ST_Distance(c.g::geography, s.geom::geography);

-- 3. Inherit from the parent -----------------------------------------------------
-- A sheet is a rink whose own name is missing or only identifies it within
-- its parent ("Rink 1", "Olympia Ice Center Rink 3").
ALTER TABLE parent ADD COLUMN sheet boolean;
UPDATE parent p SET sheet = (s.name IS NULL OR rink_name_is_sheet_of(s.name, p.p_name))
FROM stage s WHERE (s.osm_type, s.osm_id) = (p.osm_type, p.osm_id);

UPDATE stage s SET
    parent_name = p.p_name,
    parent_osm  = p.p_type || '/' || p.p_id,
    group_key   = CASE WHEN p.facility AND p.sheet THEN p.p_type || '/' || p.p_id END,
    sheet_names = CASE WHEN p.sheet AND s.name IS NOT NULL
                       THEN CASE WHEN rink_name_is_generic(s.name) THEN s.name
                            ELSE btrim(substr(s.name, length(p.p_name) + 1), ' -–—:,()') END END,
    name = CASE
        WHEN s.name IS NULL AND p.facility THEN p.p_name
        WHEN s.name IS NULL                THEN 'Ice rink at ' || p.p_name
        WHEN p.sheet AND p.facility        THEN p.p_name
        WHEN rink_name_is_generic(s.name)  THEN p.p_name || ' – ' || s.name
        ELSE s.name END,
    name_source = CASE WHEN s.name IS NULL OR (p.sheet AND p.facility) OR rink_name_is_generic(s.name)
                       THEN 'parent' ELSE 'osm' END,
    website = coalesce(s.website, w.url),
    website_source = CASE WHEN s.website IS NOT NULL THEN 'osm'
                          WHEN w.url IS NOT NULL THEN 'parent' END,
    phone    = coalesce(s.phone, nullif(btrim(coalesce(p.p_t->>'phone', p.p_t->>'contact:phone')), '')),
    email    = coalesce(s.email, nullif(btrim(coalesce(p.p_t->>'email', p.p_t->>'contact:email')), '')),
    operator = coalesce(s.operator, nullif(btrim(p.p_t->>'operator'), '')),
    -- A venue's hours are a fair proxy for its unnamed sheet; a park's are not.
    opening_hours_raw = coalesce(s.opening_hours_raw,
        CASE WHEN p.facility AND p.sheet THEN nullif(btrim(p.p_t->>'opening_hours'), '') END),
    -- A rink inside a building outline is indoors.
    indoor = coalesce(s.indoor, CASE WHEN p.is_poly AND p.is_building THEN true END),
    -- Take the parent's address only as a whole, never mixed with the rink's.
    addr_housenumber = CASE WHEN a.own THEN s.addr_housenumber ELSE nullif(btrim(p.p_t->>'addr:housenumber'), '') END,
    addr_street      = CASE WHEN a.own THEN s.addr_street      ELSE nullif(btrim(p.p_t->>'addr:street'), '') END,
    addr_city        = coalesce(s.addr_city,     nullif(btrim(p.p_t->>'addr:city'), '')),
    addr_state       = coalesce(s.addr_state,    nullif(btrim(p.p_t->>'addr:state'), '')),
    addr_postcode    = coalesce(s.addr_postcode, nullif(btrim(p.p_t->>'addr:postcode'), ''))
FROM parent p
CROSS JOIN LATERAL (SELECT coalesce(rink_clean_url(p.p_t->>'website'),
                                    rink_clean_url(p.p_t->>'contact:website'),
                                    rink_clean_url(p.p_t->>'url')) AS url) w
CROSS JOIN LATERAL (SELECT (SELECT st.addr_street IS NOT NULL OR st.addr_housenumber IS NOT NULL
                            FROM stage st
                            WHERE (st.osm_type, st.osm_id) = (p.osm_type, p.osm_id)) AS own) a
WHERE (s.osm_type, s.osm_id) = (p.osm_type, p.osm_id);

-- A sports complex that contains a separately named, mapped rink is a
-- container, not a rink of its own: "Sidney J. Watson Arena" is the rink,
-- "Pickard Field Athletic Complex" around it is not. The complex stays in
-- the context set, so the rink has already inherited its details above.
DELETE FROM stage v
WHERE v.tags->>'leisure' IN ('sports_centre', 'sports_hall')
  AND EXISTS (SELECT 1 FROM parent p JOIN stage r ON (r.osm_type, r.osm_id) = (p.osm_type, p.osm_id)
              WHERE (p.p_type, p.p_id) = (v.osm_type, v.osm_id)
                AND NOT p.sheet AND r.footprint IS NOT NULL);

-- Heuristic: a seasonal rink that is not in a building is an outdoor rink
-- (flooded park rinks, holiday rinks). Documented in the README.
UPDATE stage SET indoor = false WHERE indoor IS NULL AND seasonal;

-- Merge helper -------------------------------------------------------------------
-- Every loser donates the attributes its keeper lacks, then is removed.
-- Sheets add up when both sides are mapped outlines (two polygons = two sheets;
-- a POI node on top of an outline is the same sheet).
CREATE TEMP TABLE dupes (l_type text, l_id bigint, k_type text, k_id bigint) ON COMMIT DROP;

CREATE FUNCTION pg_temp.merge_dupes() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    UPDATE stage k SET
        name              = coalesce(k.name, d.name),
        name_source       = CASE WHEN k.name IS NULL AND d.name IS NOT NULL THEN d.name_source ELSE k.name_source END,
        parent_name       = coalesce(k.parent_name, d.parent_name),
        parent_osm        = coalesce(k.parent_osm, d.parent_osm),
        indoor            = coalesce(k.indoor, d.indoor),
        seasonal          = coalesce(k.seasonal, d.seasonal),
        opening_hours_raw = coalesce(k.opening_hours_raw, d.opening_hours_raw),
        website           = coalesce(k.website, d.website),
        website_source    = CASE WHEN k.website IS NULL THEN d.website_source ELSE k.website_source END,
        social            = coalesce(k.social, d.social),
        phone             = coalesce(k.phone, d.phone),
        email             = coalesce(k.email, d.email),
        operator          = coalesce(k.operator, d.operator),
        sports            = coalesce(k.sports, d.sports),
        addr_housenumber  = CASE WHEN k.addr_street IS NULL AND k.addr_housenumber IS NULL THEN d.addr_housenumber ELSE k.addr_housenumber END,
        addr_street       = CASE WHEN k.addr_street IS NULL AND k.addr_housenumber IS NULL THEN d.addr_street ELSE k.addr_street END,
        addr_city         = coalesce(k.addr_city, d.addr_city),
        addr_state        = coalesce(k.addr_state, d.addr_state),
        addr_postcode     = coalesce(k.addr_postcode, d.addr_postcode),
        sheets            = coalesce(k.sheets, CASE WHEN k.footprint IS NOT NULL THEN 1 ELSE 0 END) + d.sheets,
        sheet_names       = nullif(concat_ws(', ', k.sheet_names, d.sheet_names), '')
    FROM (
        SELECT d.k_type, d.k_id,
               (array_agg(l.name)              FILTER (WHERE l.name IS NOT NULL))[1]              AS name,
               (array_agg(l.name_source)       FILTER (WHERE l.name IS NOT NULL))[1]              AS name_source,
               (array_agg(l.parent_name)       FILTER (WHERE l.parent_name IS NOT NULL))[1]       AS parent_name,
               (array_agg(l.parent_osm)        FILTER (WHERE l.parent_name IS NOT NULL))[1]       AS parent_osm,
               bool_or(l.indoor)                                                                 AS indoor,
               bool_or(l.seasonal)                                                               AS seasonal,
               (array_agg(l.opening_hours_raw) FILTER (WHERE l.opening_hours_raw IS NOT NULL))[1] AS opening_hours_raw,
               (array_agg(l.website)           FILTER (WHERE l.website IS NOT NULL))[1]           AS website,
               (array_agg(l.website_source)    FILTER (WHERE l.website IS NOT NULL))[1]           AS website_source,
               (array_agg(l.social)            FILTER (WHERE l.social IS NOT NULL))[1]            AS social,
               (array_agg(l.phone)             FILTER (WHERE l.phone IS NOT NULL))[1]             AS phone,
               (array_agg(l.email)             FILTER (WHERE l.email IS NOT NULL))[1]             AS email,
               (array_agg(l.operator)          FILTER (WHERE l.operator IS NOT NULL))[1]          AS operator,
               (array_agg(l.sports)            FILTER (WHERE l.sports IS NOT NULL))[1]            AS sports,
               (array_agg(l.addr_housenumber)  FILTER (WHERE l.addr_street IS NOT NULL))[1]       AS addr_housenumber,
               (array_agg(l.addr_street)       FILTER (WHERE l.addr_street IS NOT NULL))[1]       AS addr_street,
               (array_agg(l.addr_city)         FILTER (WHERE l.addr_city IS NOT NULL))[1]         AS addr_city,
               (array_agg(l.addr_state)        FILTER (WHERE l.addr_state IS NOT NULL))[1]        AS addr_state,
               (array_agg(l.addr_postcode)     FILTER (WHERE l.addr_postcode IS NOT NULL))[1]     AS addr_postcode,
               coalesce(sum(coalesce(l.sheets, 1)) FILTER (WHERE l.footprint IS NOT NULL), 0)::int AS sheets,
               string_agg(l.sheet_names, ', ' ORDER BY length(l.sheet_names), l.sheet_names)      AS sheet_names
        FROM dupes d
        JOIN stage l ON (l.osm_type, l.osm_id) = (d.l_type, d.l_id)
        GROUP BY d.k_type, d.k_id
    ) d
    WHERE (k.osm_type, k.osm_id) = (d.k_type, d.k_id);

    DELETE FROM stage s USING dupes d WHERE (s.osm_type, s.osm_id) = (d.l_type, d.l_id);
    GET DIAGNOSTICS n = ROW_COUNT;
    TRUNCATE dupes;
    RETURN n;
END $$;

-- 4. One rink per facility ----------------------------------------------------------
-- Sheets that took their name from the same venue become one row. The keeper
-- is the venue itself when it is in the rink set (it is an outline around the
-- sheets, not a sheet, so it starts at 0), otherwise the best-tagged sheet.
UPDATE stage v SET group_key = v.osm_type || '/' || v.osm_id, sheets = 0
WHERE EXISTS (SELECT 1 FROM stage s WHERE s.group_key = v.osm_type || '/' || v.osm_id);

INSERT INTO dupes
WITH ranked AS (
    SELECT *,
           row_number() OVER (PARTITION BY group_key
                              ORDER BY (group_key = osm_type || '/' || osm_id) DESC,
                                       (footprint IS NULL),
                                       (SELECT count(*) FROM jsonb_object_keys(tags)) DESC,
                                       osm_type, osm_id) AS rnk
    FROM stage WHERE group_key IS NOT NULL
)
SELECT l.osm_type, l.osm_id, k.osm_type, k.osm_id
FROM ranked l JOIN ranked k ON k.group_key = l.group_key AND k.rnk = 1
WHERE l.rnk > 1;

SELECT pg_temp.merge_dupes() AS sheets_merged_into_facilities;

-- 5. Dedupe ----------------------------------------------------------------------------
-- Two features are the same rink when either
--   (a) a node sits within 60 m of a way/relation rink and their names do
--       not conflict (a POI node mapped on top of the building outline), or
--   (b) they share a name and are within 150 m of each other.
-- The keeper is the feature with a footprint, then the richest tag set,
-- then the lowest id. Separately-named rinks in one complex are kept.
INSERT INTO dupes
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
-- A loser whose keeper is itself a loser is re-pointed at the best keeper in
-- its chain by simply being dropped; its direct keeper already took its data.
SELECT l_type, l_id, k_type, k_id FROM pairs WHERE pick = 1;

SELECT pg_temp.merge_dupes() AS duplicates_merged;

-- 6. Curated holiday rinks ------------------------------------------------------------
-- data/holiday_rinks.csv: pop-up rinks researched from their official pages.
-- A curated rink that OSM already has (an outdoor rink within 250 m) enriches
-- that row and keeps its OSM identity; the rest are inserted as 'curated'.
CREATE TEMP TABLE cur ON COMMIT DROP AS
SELECT slug,
       ('x' || left(md5(slug), 12))::bit(48)::bigint                     AS id,
       nullif(btrim(name), '')            AS name,
       nullif(btrim(venue), '')           AS venue,
       nullif(btrim(address), '')         AS address,
       nullif(btrim(city), '')            AS city,
       nullif(btrim(state), '')           AS state,
       ST_SetSRID(ST_MakePoint(lon::float8, lat::float8), 4326)::geometry(Point, 4326) AS geom,
       CASE lower(btrim(indoor)) WHEN 'yes' THEN true WHEN 'no' THEN false END AS indoor,
       nullif(btrim(season_start), '')::date AS season_start,
       nullif(btrim(season_end), '')::date   AS season_end,
       nullif(btrim(opening_hours), '')   AS opening_hours,
       rink_clean_url(website)            AS website,
       nullif(btrim(phone), '')           AS phone,
       rink_clean_url(source_url)         AS source_url,
       nullif(btrim(verified_season), '') AS verified_season,
       nullif(btrim(confidence), '')      AS confidence,
       nullif(btrim(notes), '')           AS notes
FROM rinks_curated_raw;

CREATE TEMP TABLE cur_match ON COMMIT DROP AS
SELECT DISTINCT ON (c.slug) c.slug, s.osm_type, s.osm_id
FROM cur c
JOIN stage s ON ST_DWithin(s.geom::geography, c.geom::geography, 250)
            -- an outdoor rink this close is the same rink; one OSM calls
            -- indoor (covered pavilions) must also share the name
            AND (s.indoor IS NOT TRUE OR lower(s.name) = lower(c.name))
ORDER BY c.slug, (lower(s.name) = lower(c.name)) DESC NULLS LAST,
         ST_Distance(s.geom::geography, c.geom::geography);

UPDATE stage s SET
    source            = 'osm+curated',
    name              = c.name,
    name_source       = 'curated',
    venue             = c.venue,
    indoor            = coalesce(c.indoor, s.indoor),
    seasonal          = true,
    season_start      = c.season_start,
    season_end        = c.season_end,
    opening_hours_raw = coalesce(c.opening_hours, s.opening_hours_raw),
    website           = coalesce(c.website, s.website),
    website_source    = CASE WHEN c.website IS NOT NULL THEN 'curated' ELSE s.website_source END,
    phone             = coalesce(c.phone, s.phone),
    addr_housenumber  = CASE WHEN c.address IS NOT NULL THEN NULL ELSE s.addr_housenumber END,
    addr_street       = coalesce(c.address, s.addr_street),
    addr_city         = coalesce(c.city, s.addr_city),
    addr_state        = coalesce(c.state, s.addr_state),
    verified_season   = c.verified_season,
    source_url        = c.source_url,
    confidence        = c.confidence,
    notes             = c.notes
FROM cur c JOIN cur_match m USING (slug)
WHERE (s.osm_type, s.osm_id) = (m.osm_type, m.osm_id);

INSERT INTO stage (osm_type, osm_id, name, geom, indoor, seasonal, opening_hours_raw,
                   website, website_source, phone, addr_street, addr_city, addr_state, tags,
                   name_source, source, venue, season_start, season_end,
                   verified_season, source_url, confidence, notes, rink_type)
SELECT 'curated', c.id, c.name, c.geom, c.indoor, true, c.opening_hours,
       c.website, CASE WHEN c.website IS NOT NULL THEN 'curated' END, c.phone,
       c.address, c.city, c.state, jsonb_build_object('curated:slug', c.slug),
       'curated', 'curated', c.venue, c.season_start, c.season_end,
       c.verified_season, c.source_url, c.confidence, c.notes, 'holiday'
FROM cur c
WHERE NOT EXISTS (SELECT 1 FROM cur_match m WHERE m.slug = c.slug);

-- 7. Rink type ----------------------------------------------------------------------------
--   holiday    pop-up rink set up for the holiday season: curated rinks that
--              close by mid-February, plus OSM seasonal outdoor rinks that cannot be natural ice
--              (south of 35°N) or say so in their name / opening dates
--   seasonal   open in winter only (mostly flooded park rinks)
--   year_round indoor, or tagged seasonal=no
--   unknown    OSM says nothing either way
UPDATE stage SET rink_type = CASE
    -- Curated rinks whose season runs past mid-February are winter-season
    -- rinks (Rockefeller Center, Crown Center, ...), not holiday pop-ups.
    WHEN source <> 'osm' AND season_end > make_date(extract(year FROM season_end)::int, 2, 14)
                         AND extract(month FROM season_end) < 7 THEN 'seasonal'
    WHEN source <> 'osm' THEN 'holiday'
    WHEN seasonal AND indoor IS NOT TRUE AND (
            ST_Y(geom) < 35
         OR name ~* '\m(holiday|christmas|xmas|winter ?fest|winter village|winter wonderland|winterland|winter skate|on ice|pop.?up)\M'
         OR opening_hours_raw ~* '^(nov|dec)[^;]*-\s*(jan|feb)')
        THEN 'holiday'
    WHEN seasonal THEN 'seasonal'
    WHEN indoor OR seasonal = false THEN 'year_round'
    ELSE 'unknown' END;

-- Sheets mapped only as labelled points ("Rink 1", "Rink 2" nodes inside a
-- venue outline) are not counted above; distinct sheet labels are.
UPDATE stage SET sheets = greatest(coalesce(sheets, 0),
       (SELECT count(DISTINCT lower(x)) FROM unnest(string_to_array(sheet_names, ', ')) x))
WHERE sheet_names IS NOT NULL;

UPDATE stage SET
    sheets      = CASE WHEN sheets >= 2 THEN sheets END,      -- 1 mapped sheet says nothing
    sheet_names = CASE WHEN sheets >= 2 THEN
                      (SELECT string_agg(x, ', ' ORDER BY length(x), x)
                       FROM unnest(string_to_array(sheet_names, ', ')) x) END,
    name_source = CASE WHEN name IS NULL THEN 'none' ELSE name_source END;

-- Upsert -----------------------------------------------------------------------------------
INSERT INTO rinks AS r (
    osm_type, osm_id, name, name_source, parent_name, parent_osm, geom, footprint,
    indoor, seasonal, opening_hours_raw, hours_status,
    website, website_source, social, phone, email, operator, sports, sheets, sheet_names,
    addr_housenumber, addr_street, addr_city, addr_state, addr_postcode,
    source, rink_type, venue, season_start, season_end, verified_season, source_url, confidence, notes,
    tags, updated_at)
SELECT
    osm_type, osm_id, name, name_source, parent_name, parent_osm, geom, footprint,
    indoor, seasonal, opening_hours_raw,
    -- Missing hours are UNKNOWN, never "closed".
    CASE WHEN opening_hours_raw IS NULL THEN 'unknown' ELSE 'known' END,
    website, website_source, social, phone, email, operator, sports, sheets, sheet_names,
    addr_housenumber, addr_street, addr_city, addr_state, addr_postcode,
    source, rink_type, venue, season_start, season_end, verified_season, source_url, confidence, notes,
    tags, now()
FROM stage
ON CONFLICT (osm_type, osm_id) DO UPDATE SET
    name = EXCLUDED.name, name_source = EXCLUDED.name_source,
    parent_name = EXCLUDED.parent_name, parent_osm = EXCLUDED.parent_osm,
    geom = EXCLUDED.geom, footprint = EXCLUDED.footprint,
    indoor = EXCLUDED.indoor, seasonal = EXCLUDED.seasonal,
    opening_hours_raw = EXCLUDED.opening_hours_raw, hours_status = EXCLUDED.hours_status,
    website = EXCLUDED.website, website_source = EXCLUDED.website_source,
    social = EXCLUDED.social, phone = EXCLUDED.phone, email = EXCLUDED.email,
    operator = EXCLUDED.operator, sports = EXCLUDED.sports,
    sheets = EXCLUDED.sheets, sheet_names = EXCLUDED.sheet_names,
    addr_housenumber = EXCLUDED.addr_housenumber, addr_street = EXCLUDED.addr_street,
    addr_city = EXCLUDED.addr_city, addr_state = EXCLUDED.addr_state,
    addr_postcode = EXCLUDED.addr_postcode,
    source = EXCLUDED.source, rink_type = EXCLUDED.rink_type, venue = EXCLUDED.venue,
    season_start = EXCLUDED.season_start, season_end = EXCLUDED.season_end,
    verified_season = EXCLUDED.verified_season, source_url = EXCLUDED.source_url,
    confidence = EXCLUDED.confidence, notes = EXCLUDED.notes,
    tags = EXCLUDED.tags, updated_at = EXCLUDED.updated_at;

DELETE FROM rinks r
WHERE NOT EXISTS (SELECT 1 FROM stage s
                  WHERE (s.osm_type, s.osm_id) = (r.osm_type, r.osm_id));

COMMIT;

ANALYZE rinks;

SELECT count(*)                                              AS rinks,
       count(*) FILTER (WHERE name_source = 'osm')           AS named_in_osm,
       count(*) FILTER (WHERE name_source = 'parent')        AS named_from_parent,
       count(*) FILTER (WHERE name IS NULL)                  AS unnamed,
       count(*) FILTER (WHERE rink_name_is_generic(name))    AS still_generic,
       count(website)                                        AS website,
       count(*) FILTER (WHERE website_source = 'parent')     AS website_from_parent,
       count(*) FILTER (WHERE addr_city IS NOT NULL OR addr_street IS NOT NULL) AS address,
       count(*) FILTER (WHERE sheets IS NOT NULL)            AS multi_sheet
FROM rinks;

SELECT count(*) FILTER (WHERE indoor)                   AS indoor,
       count(*) FILTER (WHERE indoor = false)           AS outdoor,
       count(*) FILTER (WHERE indoor IS NULL)           AS indoor_unknown,
       count(*) FILTER (WHERE hours_status = 'known')   AS hours_known,
       (SELECT count(*) FROM rinks_raw WHERE NOT rink_is_ice_venue(tags::jsonb)) AS dropped_not_ice,
       (SELECT count(*) FROM rinks_raw WHERE rink_is_ice_venue(tags::jsonb))
         - count(*) FILTER (WHERE osm_type <> 'curated')  AS merged_away
FROM rinks;

SELECT rink_type, source, count(*) FROM rinks GROUP BY 1, 2 ORDER BY 1, 2;
