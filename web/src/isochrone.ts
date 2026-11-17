// Drive-time polygons. The rest of the app only ever calls getIsochrone(),
// so swapping the third-party API for your own Valhalla / pgRouting endpoint
// is a change to this file (or just VITE_VALHALLA_URL) and nothing else.
import type { Feature, MultiPolygon, Polygon } from 'geojson';
import { ORS_API_KEY, VALHALLA_URL } from './config';

export type Isochrone = Feature<Polygon | MultiPolygon>;

const cache = new Map<string, Promise<Isochrone>>();

export const ISOCHRONE_ATTRIBUTION = ORS_API_KEY
  ? '© <a href="https://openrouteservice.org/" target="_blank" rel="noopener">openrouteservice.org</a> by HeiGIT'
  : 'Routing by <a href="https://github.com/valhalla/valhalla" target="_blank" rel="noopener">Valhalla</a> / <a href="https://www.fossgis.de/" target="_blank" rel="noopener">FOSSGIS</a>';

/** Area reachable by car from `lngLat` within `minutes`. Cached per point + minutes. */
export function getIsochrone(lngLat: [number, number], minutes: number): Promise<Isochrone> {
  // ~11 m precision: dragging the pin a hair doesn't burn quota.
  const lng = Number(lngLat[0].toFixed(4));
  const lat = Number(lngLat[1].toFixed(4));
  const key = `${lng},${lat},${minutes}`;
  let hit = cache.get(key);
  if (!hit) {
    hit = (ORS_API_KEY ? fromOrs(lng, lat, minutes, ORS_API_KEY) : fromValhalla(lng, lat, minutes));
    cache.set(key, hit);
    hit.catch(() => cache.delete(key)); // don't cache failures
  }
  return hit;
}

function firstPolygon(fc: unknown): Isochrone {
  const f = (fc as { features?: Feature[] })?.features?.[0];
  const t = f?.geometry?.type;
  if (!f || (t !== 'Polygon' && t !== 'MultiPolygon')) {
    throw new Error('Routing service returned no drive-time area for this point.');
  }
  return { type: 'Feature', properties: {}, geometry: f.geometry as Polygon | MultiPolygon };
}

async function fromValhalla(lng: number, lat: number, minutes: number): Promise<Isochrone> {
  const body = {
    locations: [{ lat, lon: lng }],
    costing: 'auto',
    contours: [{ time: minutes }],
    polygons: true,
    denoise: 0.5,
    generalize: 100,
  };
  const res = await fetch(`${VALHALLA_URL}/isochrone?json=${encodeURIComponent(JSON.stringify(body))}`);
  if (!res.ok) throw new Error(`Drive-time request failed (${res.status}).`);
  return firstPolygon(await res.json());
}

async function fromOrs(lng: number, lat: number, minutes: number, key: string): Promise<Isochrone> {
  const res = await fetch('https://api.openrouteservice.org/v2/isochrones/driving-car', {
    method: 'POST',
    headers: { Authorization: key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ locations: [[lng, lat]], range: [minutes * 60], range_type: 'time' }),
  });
  if (!res.ok) throw new Error(`Drive-time request failed (${res.status}).`);
  return firstPolygon(await res.json());
}
