import * as maplibregl from 'maplibre-gl';
import {
  type ExpressionSpecification, type GeoJSONSource, type MapGeoJSONFeature, type VectorSourceSpecification,
} from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
// MapLibre 6 ships its worker as a separate ES module; it is self-contained, so serve it as an asset.
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?url';
import { Protocol } from 'pmtiles';
import type { Feature, FeatureCollection, Point } from 'geojson';
import './style.css';
import { BASEMAP_STYLE, DEFAULT_VIEW, GEOCODER_URL, SOURCE_LAYER, TILE_MAXZOOM, TILE_SOURCE } from './config';
import { buildFilter, circlePolygon, type AreaFilter, type FilterState, type HoursResult, type IndoorValue, type RinkType } from './filters';
import { describeHours, formatDay, hoursState, queryMoment, seasonPhase, wallClockAt, type HoursQuery } from './hours';
import { getIsochrone, ISOCHRONE_ATTRIBUTION } from './isochrone';

const RINKS = 'rinks';
const COLORS = { yes: '#1d4ed8', no: '#ea580c', unknown: '#6b7280' };
const HOLIDAY_RING = '#db2777';

// --- Tile source: the one static/realtime switch ---------------------------
maplibregl.setWorkerUrl(workerUrl);
maplibregl.addProtocol('pmtiles', new Protocol().tile);

function rinkSource(): VectorSourceSpecification {
  const attribution = '© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors';
  const base = { type: 'vector' as const, promoteId: 'id', attribution };
  // "{z}" => raw XYZ endpoint (Martin); otherwise a TileJSON / pmtiles:// URL.
  return TILE_SOURCE.includes('{z}')
    ? { ...base, tiles: [TILE_SOURCE], maxzoom: TILE_MAXZOOM }
    : { ...base, url: TILE_SOURCE };
}

// --- URL state: ?center=lng,lat&zoom=z --------------------------------------
function readView() {
  const q = new URLSearchParams(location.search);
  const [lng, lat] = (q.get('center') ?? '').split(',').map(Number);
  const zoom = Number(q.get('zoom'));
  const ok = Number.isFinite(lng) && Number.isFinite(lat) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180;
  return {
    center: ok ? ([lng, lat] as [number, number]) : DEFAULT_VIEW.center,
    zoom: q.has('zoom') && Number.isFinite(zoom) ? Math.min(Math.max(zoom, 0), 20) : DEFAULT_VIEW.zoom,
  };
}

function writeView() {
  const c = map.getCenter();
  const q = new URLSearchParams(location.search);
  q.set('center', `${c.lng.toFixed(5)},${c.lat.toFixed(5)}`);
  q.set('zoom', map.getZoom().toFixed(2));
  // Keep the comma readable in the address bar.
  history.replaceState(null, '', `${location.pathname}?${q.toString().replace(/%2C/g, ',')}${location.hash}`);
}

const map = new maplibregl.Map({
  container: 'map',
  style: BASEMAP_STYLE,
  ...readView(),
  minZoom: 2,
  attributionControl: { compact: window.innerWidth < 640 },
});
map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
map.addControl(new maplibregl.GeolocateControl({ trackUserLocation: false }), 'top-right');
map.on('moveend', writeView);

// --- Filter state ------------------------------------------------------------
const state: FilterState = {
  indoor: new Set<IndoorValue>(['yes', 'no', 'unknown']),
  types: new Set<RinkType>(['year_round', 'seasonal', 'holiday', 'unknown']),
  inSeasonOnly: false,
  hours: { mode: 'any' },
  includeUnknownHours: true,
  area: { mode: 'off' },
};
let areaMode: 'off' | 'radius' | 'drive' = 'off';
let origin: [number, number] | null = null;
let originMarker: maplibregl.Marker | null = null;

/** Every rink seen in any loaded tile: id -> what hours evaluation needs. */
const seen = new Map<string, { oh?: string; lat: number; lon: number; start?: string; end?: string }>();
let hoursResult: HoursResult = { open: [], unparseable: [], outOfSeason: [] };

const $ = <T extends HTMLElement>(sel: string) => document.querySelector<T>(sel)!;
const countEl = $('#count');
const areaNote = $('#area-note');
const AREA_HINT = areaNote.textContent!;

function collectFeatures(): boolean {
  let added = false;
  for (const f of map.querySourceFeatures(RINKS, { sourceLayer: SOURCE_LAYER })) {
    const id = f.properties.id as string;
    if (seen.has(id) || f.geometry.type !== 'Point') continue;
    const [lon, lat] = f.geometry.coordinates;
    seen.set(id, { oh: f.properties.opening_hours, lat, lon, start: f.properties.season_start, end: f.properties.season_end });
    added = true;
  }
  return added;
}

function evaluateHours(q: HoursQuery): HoursResult {
  const open: string[] = [];
  const unparseable: string[] = [];
  const outOfSeason: string[] = [];
  if (q.mode === 'any') return { open, unparseable, outOfSeason };
  const now = new Date();
  for (const [id, r] of seen) {
    if (!r.oh && !r.start) continue; // hours_status = 'unknown' handles these in the filter
    const at = queryMoment(q, r.lat, r.lon, now);
    const phase = seasonPhase(r, at);
    if (phase === 'before' || phase === 'after') { outOfSeason.push(id); continue; }
    if (!r.oh) continue;
    const s = hoursState(r.oh, r.lat, r.lon, at);
    if (s === 'open') open.push(id);
    else if (s === 'unknown') unparseable.push(id);
  }
  return { open, unparseable, outOfSeason };
}

function applyFilters() {
  if (!map.getLayer(RINKS)) return;
  hoursResult = evaluateHours(state.hours);
  const filter = buildFilter(state, hoursResult);
  map.setFilter(RINKS, filter);
  map.setFilter(`${RINKS}-label`, filter);

  // With a time filter on, rinks whose hours aren't listed render hollow so
  // "unknown" is visibly different from "open".
  const hollow = state.hours.mode !== 'any';
  const unknownHours: ExpressionSpecification = ['any',
    ['==', ['get', 'hours_status'], 'unknown'],
    ['in', ['get', 'id'], ['literal', hoursResult.unparseable]]];
  map.setPaintProperty(RINKS, 'circle-opacity', hollow ? ['case', unknownHours, 0.12, 1] : 1);
  map.setPaintProperty(RINKS, 'circle-stroke-color', hollow ? ['case', IS_HOLIDAY, HOLIDAY_RING, unknownHours, COLOR_EXPR, '#ffffff'] : STROKE_EXPR);
  document.body.classList.toggle('time-filter', hollow);
}

function updateCount() {
  if (!map.getLayer(RINKS)) return;
  const ids = new Set(map.queryRenderedFeatures({ layers: [RINKS] }).map((f) => f.properties.id));
  const n = ids.size;
  const filtered = state.indoor.size < 3 || state.types.size < 4 || state.inSeasonOnly || state.hours.mode !== 'any' || state.area.mode !== 'off';
  countEl.textContent = `${n.toLocaleString()} rink${n === 1 ? '' : 's'} ${filtered ? 'match' : ''} in view`.replace('  ', ' ');
}

const COLOR_EXPR: ExpressionSpecification = ['match', ['get', 'indoor'], 'yes', COLORS.yes, 'no', COLORS.no, COLORS.unknown];
// Holiday pop-ups get a pink ring so they stand out from permanent rinks.
const IS_HOLIDAY: ExpressionSpecification = ['==', ['get', 'rink_type'], 'holiday'];
const STROKE_EXPR: ExpressionSpecification = ['case', IS_HOLIDAY, HOLIDAY_RING, '#ffffff'];

map.on('load', () => {
  map.addSource(RINKS, rinkSource());
  map.addSource('area', { type: 'geojson', data: emptyFc() });

  map.addLayer({ id: 'area-fill', type: 'fill', source: 'area', paint: { 'fill-color': '#0ea5e9', 'fill-opacity': 0.1 } });
  map.addLayer({ id: 'area-line', type: 'line', source: 'area', paint: { 'line-color': '#0284c7', 'line-width': 2, 'line-dasharray': [2, 1.5] } });

  map.addLayer({
    id: RINKS, type: 'circle', source: RINKS, 'source-layer': SOURCE_LAYER,
    // Draw holiday rinks on top of the dense permanent ones.
    layout: { 'circle-sort-key': ['case', IS_HOLIDAY, 1, 0] },
    paint: {
      'circle-radius': ['interpolate', ['linear'], ['zoom'], 3, 2.6, 7, 4.5, 11, 6.5, 15, 9],
      'circle-color': COLOR_EXPR,
      'circle-stroke-color': STROKE_EXPR,
      'circle-stroke-width': ['interpolate', ['linear'], ['zoom'],
        3, ['case', IS_HOLIDAY, 1.4, 0.6], 10, ['case', IS_HOLIDAY, 2.6, 1.6]],
    },
  });
  map.addLayer({
    id: `${RINKS}-label`, type: 'symbol', source: RINKS, 'source-layer': SOURCE_LAYER, minzoom: 10,
    layout: {
      'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': 12,
      'text-offset': [0, 1.1], 'text-anchor': 'top', 'text-optional': true, 'text-max-width': 9,
    },
    paint: { 'text-color': '#1f2937', 'text-halo-color': '#ffffff', 'text-halo-width': 1.4 },
  });

  map.on('mouseenter', RINKS, () => (map.getCanvas().style.cursor = 'pointer'));
  map.on('mouseleave', RINKS, () => (map.getCanvas().style.cursor = ''));
  map.on('click', onMapClick);
  map.on('idle', () => {
    // New tiles can reveal rinks we haven't evaluated hours for yet.
    if (collectFeatures() && state.hours.mode !== 'any') applyFilters();
    updateCount();
  });
  applyFilters();
});

// Keep "open now" honest while the tab stays open.
setInterval(() => { if (state.hours.mode === 'now') applyFilters(); }, 60_000);

// --- Popup -------------------------------------------------------------------
function el<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, cls?: string) {
  const n = document.createElement(tag);
  if (text) n.textContent = text;
  if (cls) n.className = cls;
  return n;
}

function link(text: string, href: string, cls?: string) {
  const a = el('a', text, cls);
  a.href = href;
  if (/^https?:/i.test(href)) { a.target = '_blank'; a.rel = 'noopener noreferrer'; }
  return a;
}

/** "https://www.example.com/rink/" -> "example.com/rink" */
function displayUrl(url: string): string {
  try {
    const u = new URL(url);
    const path = u.pathname.replace(/\/+$/, '');
    const text = u.hostname.replace(/^www\./, '') + path;
    return text.length > 38 ? `${text.slice(0, 37)}…` : text;
  } catch {
    return url;
  }
}

function row(label: string, value: Node | string) {
  const r = el('div', undefined, 'field');
  r.append(el('span', label, 'label'));
  const v = el('span', undefined, 'value');
  v.append(value);
  r.append(v);
  return r;
}

function popupContent(f: MapGeoJSONFeature): HTMLElement {
  const p = f.properties as Record<string, string | number | undefined>;
  const str = (k: string) => (p[k] == null || p[k] === '' ? undefined : String(p[k]));
  const [lon, lat] = (f.geometry as Point).coordinates;
  const root = el('div', undefined, 'rink-popup');
  const name = str('name') || 'Ice rink';
  const unnamed = str('name_source') === 'none';
  root.append(el('h2', name));

  // One line of facts: setting, season, sheets, sports.
  const facts = [p.indoor === 'yes' ? 'Indoor' : p.indoor === 'no' ? 'Outdoor' : 'Indoor/outdoor not tagged'];
  if (p.rink_type === 'holiday') facts.unshift('Holiday pop-up');
  else if (p.seasonal === 'yes') facts.push('Winter season');
  if (Number(p.sheets) >= 2) facts.push(`${p.sheets} ice sheets`);
  root.append(el('p', facts.join(' · '), 'meta'));
  if (str('venue')) root.append(el('p', `At ${str('venue')}`, 'meta'));
  if (unnamed) root.append(el('p', 'No name in OpenStreetMap', 'meta'));
  else if (str('name_source') === 'parent') root.append(el('p', 'Named after the place it is in', 'meta'));

  // Published season (holiday pop-ups): dates plus where today falls.
  const season = { start: str('season_start'), end: str('season_end') };
  const phase = seasonPhase(season, wallClockAt(lat, lon, new Date()));
  if (phase) {
    const line = el('p', undefined, 'season');
    line.append(el('span',
      phase === 'in' ? `In season · through ${formatDay(season.end!, false)}`
        : phase === 'before' ? `Opens ${formatDay(season.start!, false)}` : 'Season ended',
      `badge ${phase === 'in' ? 'season' : 'unknown'}`));
    line.append(el('span', ` ${formatDay(season.start!)} – ${formatDay(season.end!)}`, 'muted'));
    root.append(line);
  }

  const h = describeHours(str('opening_hours'), lat, lon);
  if (phase === 'before' || phase === 'after') {
    h.state = 'closed';
    h.label = phase === 'before' ? 'Not open yet' : 'Closed for the season';
  } else if (phase === 'in' && !str('opening_hours')) {
    h.label = 'Hours vary — check the website';
  }
  const hours = el('p', undefined, 'hours');
  hours.append(el('span', h.label, `badge ${h.state}`));
  if (h.pretty) hours.append(el('span', h.pretty, 'raw'));
  root.append(hours);

  const fields = el('div', undefined, 'fields');
  const website = str('website');
  if (website && /^https?:\/\//i.test(website)) {
    const v = document.createDocumentFragment();
    v.append(link(displayUrl(website), website));
    if (str('website_source') === 'parent' && str('parent_name') && str('parent_name') !== name) {
      v.append(el('span', ` (${str('parent_name')})`, 'muted'));
    } else if (str('website_source') === 'wikidata') {
      v.append(el('span', ' (via Wikidata)', 'muted'));
    }
    fields.append(row('Website', v));
  } else {
    // No website in OSM: fall back to a social page, then to a web search.
    const v = document.createDocumentFragment();
    const social = str('social');
    if (social && /^https?:\/\//i.test(social)) v.append(link(displayUrl(social), social));
    else {
      v.append(el('span', 'Not listed', 'muted'));
      if (!unnamed) {
        const q = [name, str('city'), str('state')].filter(Boolean).join(' ');
        v.append(' · ', link('Search the web', `https://duckduckgo.com/?q=${encodeURIComponent(q)}`));
      }
    }
    fields.append(row('Website', v));
  }
  if (str('address')) {
    const v = document.createDocumentFragment();
    v.append(str('address')!);
    if (str('address_source') === 'wikidata') v.append(el('span', ' (via Wikidata)', 'muted'));
    fields.append(row('Address', v));
  } else if (str('locality')) {
    // No street address anywhere: say roughly where it is (Census boundaries).
    fields.append(row('Location', `Near ${str('locality')}`));
  }
  if (str('phone')) fields.append(row('Phone', link(str('phone')!, `tel:${str('phone')!.replace(/[^\d+]/g, '')}`)));
  if (str('email') && /^[^\s@]+@[^\s@]+$/.test(str('email')!)) fields.append(row('Email', link(str('email')!, `mailto:${str('email')}`)));
  if (str('sheet_names')) fields.append(row('Sheets', str('sheet_names')!));
  if (str('sports')) fields.append(row('Sports', str('sports')!));
  if (str('operator') && str('operator') !== name) fields.append(row('Operator', str('operator')!));
  if (str('notes')) fields.append(row('Note', str('notes')!));
  if (str('verified_season')) {
    const v = document.createDocumentFragment();
    v.append(`${str('verified_season')} season`);
    if (str('confidence') && str('confidence') !== 'high') v.append(el('span', ` · ${str('confidence')} confidence`, 'muted'));
    const src = str('source_url');
    if (src && /^https?:\/\//i.test(src)) v.append(' · ', link('source', src));
    fields.append(row('Verified', v));
  }
  root.append(fields);

  const links = el('p', undefined, 'links');
  links.append(link('Directions', `https://www.openstreetmap.org/directions?to=${lat.toFixed(6)},${lon.toFixed(6)}`));
  // Map apps often have the phone, website and hours that OSM lacks. Link to
  // them rather than copying their data. Named rinks are searched by name
  // near the point; unnamed ones just open the coordinates.
  const ll = `${lat.toFixed(6)},${lon.toFixed(6)}`;
  const mapQuery = unnamed ? ll : [name, str('locality')].filter(Boolean).join(', ');
  links.append(link('Google Maps', `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(mapQuery)}`));
  links.append(link('Apple Maps', unnamed
    ? `https://maps.apple.com/?ll=${ll}&q=${encodeURIComponent('Ice rink')}`
    : `https://maps.apple.com/?q=${encodeURIComponent(name)}&sll=${ll}&z=16`));
  const m = /^([nwr])(\d+)$/.exec(str('id') ?? '');
  if (m) {
    const type = { n: 'node', w: 'way', r: 'relation' }[m[1] as 'n' | 'w' | 'r'];
    links.append(link('View / fix on OpenStreetMap', `https://www.openstreetmap.org/${type}/${m[2]}`));
  }
  root.append(links);
  return root;
}

function onMapClick(e: maplibregl.MapMouseEvent) {
  const hit = map.queryRenderedFeatures(e.point, { layers: [RINKS] })[0];
  if (hit) {
    new maplibregl.Popup({ maxWidth: '320px', offset: 8 })
      .setLngLat((hit.geometry as Point).coordinates as [number, number])
      .setDOMContent(popupContent(hit))
      .addTo(map);
  } else if (areaMode !== 'off') {
    setOrigin([e.lngLat.lng, e.lngLat.lat], false);
  }
}

// --- Near: radius / drive time -------------------------------------------------
function emptyFc(): FeatureCollection { return { type: 'FeatureCollection', features: [] }; }

function setOrigin(lngLat: [number, number], fly: boolean) {
  origin = lngLat;
  if (!originMarker) {
    originMarker = new maplibregl.Marker({ color: '#0284c7', draggable: true }).setLngLat(lngLat).addTo(map);
    originMarker.on('dragend', () => {
      const p = originMarker!.getLngLat();
      setOrigin([p.lng, p.lat], false);
    });
  } else {
    originMarker.setLngLat(lngLat);
  }
  if (fly && areaMode === 'off') map.flyTo({ center: lngLat, zoom: Math.max(map.getZoom(), 10) });
  void updateArea(true);
}

let areaRequest = 0;
async function updateArea(fit: boolean) {
  const request = ++areaRequest;
  const src = map.getSource<GeoJSONSource>('area');
  if (!src) return;
  let area: AreaFilter = { mode: 'off' };
  let shape: Feature | null = null;
  areaNote.classList.remove('error');

  if (areaMode !== 'off' && !origin) {
    areaNote.textContent = 'Click the map or search for a place to set the starting point.';
  } else if (areaMode === 'radius' && origin) {
    const miles = Number($<HTMLSelectElement>('#radius-miles').value);
    area = { mode: 'radius', center: origin, miles };
    shape = circlePolygon(origin, miles);
    areaNote.textContent = `Straight-line distance from the pin. Drag the pin to move it.`;
  } else if (areaMode === 'drive' && origin) {
    const minutes = Number($<HTMLSelectElement>('#drive-minutes').value);
    areaNote.textContent = 'Calculating drive-time area…';
    try {
      const polygon = await getIsochrone(origin, minutes);
      if (request !== areaRequest) return; // superseded by a newer request
      area = { mode: 'drive', polygon };
      shape = polygon;
      areaNote.innerHTML = `Typical driving time without live traffic. ${ISOCHRONE_ATTRIBUTION}`;
    } catch (err) {
      if (request !== areaRequest) return;
      areaNote.textContent = `${err instanceof Error ? err.message : 'Drive-time lookup failed.'} Showing all rinks instead.`;
      areaNote.classList.add('error');
    }
  } else {
    areaNote.textContent = AREA_HINT;
  }

  state.area = area;
  src.setData(shape ?? emptyFc());
  applyFilters();
  if (shape && fit) {
    const b = new maplibregl.LngLatBounds();
    const walk = (c: unknown): void => {
      if (typeof (c as number[])[0] === 'number') b.extend(c as [number, number]);
      else (c as unknown[]).forEach(walk);
    };
    walk((shape.geometry as { coordinates: unknown }).coordinates);
    const narrow = window.innerWidth < 640;
    map.fitBounds(b, { padding: narrow ? 40 : { top: 60, bottom: 60, right: 60, left: 360 }, maxZoom: 13 });
  }
}

// --- Controls ----------------------------------------------------------------
document.querySelectorAll<HTMLInputElement>('input[name="indoor"]').forEach((box) =>
  box.addEventListener('change', () => {
    const v = box.value as IndoorValue;
    if (box.checked) state.indoor.add(v); else state.indoor.delete(v);
    applyFilters();
  }));

document.querySelectorAll<HTMLInputElement>('input[name="type"]').forEach((box) =>
  box.addEventListener('change', () => {
    const v = box.value as RinkType;
    if (box.checked) state.types.add(v); else state.types.delete(v);
    applyFilters();
  }));
$<HTMLInputElement>('#in-season').addEventListener('change', (e) => {
  state.inSeasonOnly = (e.target as HTMLInputElement).checked;
  applyFilters();
});

function readHours() {
  const mode = $<HTMLInputElement>('input[name="hours"]:checked').value as HoursQuery['mode'];
  state.hours = mode === 'at'
    ? { mode, day: Number($<HTMLSelectElement>('#hours-day').value), time: $<HTMLInputElement>('#hours-time').value || '18:00' }
    : { mode };
  state.includeUnknownHours = $<HTMLInputElement>('#hours-unknown').checked;
  applyFilters();
}
document.querySelectorAll<HTMLInputElement>('input[name="hours"]').forEach((r) => r.addEventListener('change', readHours));
$('#hours-unknown').addEventListener('change', readHours);
for (const id of ['#hours-day', '#hours-time']) {
  $(id).addEventListener('change', () => {
    $<HTMLInputElement>('input[name="hours"][value="at"]').checked = true;
    readHours();
  });
}
$<HTMLSelectElement>('#hours-day').value = String(new Date().getDay());

document.querySelectorAll<HTMLInputElement>('input[name="area"]').forEach((r) =>
  r.addEventListener('change', () => {
    areaMode = r.value as typeof areaMode;
    map.getCanvas().classList.toggle('picking', areaMode !== 'off');
    void updateArea(true);
  }));
$('#radius-miles').addEventListener('change', () => {
  $<HTMLInputElement>('input[name="area"][value="radius"]').checked = true;
  areaMode = 'radius';
  void updateArea(true);
});
$('#drive-minutes').addEventListener('change', () => {
  $<HTMLInputElement>('input[name="area"][value="drive"]').checked = true;
  areaMode = 'drive';
  void updateArea(true);
});

$<HTMLFormElement>('#search').addEventListener('submit', async (e) => {
  e.preventDefault();
  const q = $<HTMLInputElement>('#search-q').value.trim();
  if (!q) return;
  areaNote.classList.remove('error');
  try {
    const url = `${GEOCODER_URL}?${new URLSearchParams({ q, format: 'jsonv2', countrycodes: 'us', limit: '1' })}`;
    const res = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!res.ok) throw new Error(`Search failed (${res.status}).`);
    const [top] = (await res.json()) as { lon: string; lat: string }[];
    if (!top) throw new Error(`No place found for “${q}”.`);
    setOrigin([Number(top.lon), Number(top.lat)], true);
  } catch (err) {
    areaNote.textContent = err instanceof Error ? err.message : 'Search failed.';
    areaNote.classList.add('error');
  }
});

// Mobile: the panel is a collapsible sheet.
const panel = $('#panel');
const toggle = $('#panel-toggle');
toggle.addEventListener('click', () => {
  const open = panel.classList.toggle('closed') === false;
  toggle.setAttribute('aria-expanded', String(open));
});
if (window.innerWidth < 640) { panel.classList.add('closed'); toggle.setAttribute('aria-expanded', 'false'); }

// Handy for debugging / verifying filters from the console.
Object.assign(window, { rinkMap: map });
