// Filter state -> one MapLibre filter expression. The expression reads only
// tile properties (id, indoor, hours_status) and feature geometry, so it is
// the same against PMTiles and Martin.
import type { ExpressionSpecification, FilterSpecification } from 'maplibre-gl';
import type { Feature, MultiPolygon, Polygon } from 'geojson';
import type { HoursQuery } from './hours';

export type IndoorValue = 'yes' | 'no' | 'unknown';

export type AreaFilter =
  | { mode: 'off' }
  | { mode: 'radius'; center: [number, number]; miles: number }
  | { mode: 'drive'; polygon: Feature<Polygon | MultiPolygon> };

export interface FilterState {
  indoor: Set<IndoorValue>;
  hours: HoursQuery;
  includeUnknownHours: boolean;
  area: AreaFilter;
}

/** Ids whose listed hours evaluate to open / can't be evaluated at the queried time. */
export interface HoursResult {
  open: string[];
  unparseable: string[];
}

export const METERS_PER_MILE = 1609.344;

export function buildFilter(state: FilterState, hours: HoursResult): FilterSpecification {
  const all: ExpressionSpecification[] = [
    ['in', ['get', 'indoor'], ['literal', [...state.indoor]]],
  ];

  if (state.hours.mode !== 'any') {
    const any: ExpressionSpecification[] = [['in', ['get', 'id'], ['literal', hours.open]]];
    if (state.includeUnknownHours) {
      any.push(['==', ['get', 'hours_status'], 'unknown']);
      any.push(['in', ['get', 'id'], ['literal', hours.unparseable]]);
    }
    all.push(['any', ...any]);
  }

  if (state.area.mode === 'radius') {
    const point = { type: 'Point' as const, coordinates: state.area.center };
    all.push(['<=', ['distance', point], state.area.miles * METERS_PER_MILE]);
  } else if (state.area.mode === 'drive') {
    all.push(['within', state.area.polygon]);
  }

  return ['all', ...all];
}

/** Geodesic circle as a polygon, for drawing the radius on the map. */
export function circlePolygon(center: [number, number], miles: number, steps = 96): Feature<Polygon> {
  const R = 6371008.8;
  const d = (miles * METERS_PER_MILE) / R;
  const [lng, lat] = center.map((v) => (v * Math.PI) / 180);
  const ring: [number, number][] = [];
  for (let i = 0; i <= steps; i++) {
    const brng = (i / steps) * 2 * Math.PI;
    const lat2 = Math.asin(Math.sin(lat) * Math.cos(d) + Math.cos(lat) * Math.sin(d) * Math.cos(brng));
    const lng2 = lng + Math.atan2(Math.sin(brng) * Math.sin(d) * Math.cos(lat), Math.cos(d) - Math.sin(lat) * Math.sin(lat2));
    ring.push([(lng2 * 180) / Math.PI, (lat2 * 180) / Math.PI]);
  }
  return { type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: [ring] } };
}
