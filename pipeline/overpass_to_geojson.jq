# Overpass JSON (out tags geom) -> newline-delimited GeoJSON features.
#   node                -> Point
#   closed way          -> Polygon (PostGIS derives the point + footprint)
#   open way / relation -> Point at the centre of its bounding box
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
