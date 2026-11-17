# Overpass JSON (out tags geom) -> newline-delimited GeoJSON features.
#   node                -> Point
#   closed way          -> Polygon (PostGIS derives the point + footprint)
#   open way / relation -> Point at the centre of its bounding box
#                          (or, with --arg relbox 1, relations become their
#                          bounding-box Polygon: used for context features,
#                          where we need "does this area contain the rink?")
def bbox_center:
  { type: "Point",
    coordinates: [ (.bounds.minlon + .bounds.maxlon) / 2,
                   (.bounds.minlat + .bounds.maxlat) / 2 ] };

.elements[]
| select(.type == "node" or .bounds != null)
| . as $e
| ( if .type == "node" then
      { type: "Point", coordinates: [.lon, .lat] }
    elif .type == "way"
         and ((.geometry // []) | length) >= 4
         and .geometry[0] == .geometry[-1] then
      { type: "Polygon", coordinates: [ [ .geometry[] | [.lon, .lat] ] ] }
    elif .type == "relation" and ($ARGS.named.relbox // "") == "1" then
      .bounds as $b
      | { type: "Polygon", coordinates: [ [ [$b.minlon, $b.minlat], [$b.maxlon, $b.minlat],
                                            [$b.maxlon, $b.maxlat], [$b.minlon, $b.maxlat],
                                            [$b.minlon, $b.minlat] ] ] }
    else
      bbox_center
    end ) as $geom
| { type: "Feature",
    geometry: $geom,
    properties: {
      osm_type: $e.type,
      osm_id:   $e.id,
      tags:     (($e.tags // {}) | tojson)
    } }
