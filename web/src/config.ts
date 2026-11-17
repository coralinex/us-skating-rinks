// All deployment-specific values live here.
//
// TILE_SOURCE is the ONLY thing that differs between static and realtime
// mode. Layer id, source-layer name and property names are identical in both.
//   static   : "pmtiles://https://host/rinks.pmtiles"  (or the bundled file)
//   realtime : "https://host/rinks/{z}/{x}/{y}"         (Martin)

const env = import.meta.env;

const bundledPmtiles =
  'pmtiles://' + new URL(`${env.BASE_URL}rinks.pmtiles`, window.location.href).href;

export const TILE_SOURCE: string = env.VITE_TILE_SOURCE || bundledPmtiles;

/** Vector tile layer name: tippecanoe `-l rinks` / Martin source id `rinks`. */
export const SOURCE_LAYER = 'rinks';
export const TILE_MAXZOOM = 14;

export const BASEMAP_STYLE: string =
  env.VITE_BASEMAP_STYLE || 'https://tiles.openfreemap.org/styles/positron';

export const DEFAULT_VIEW = { center: [-96.5, 39.5] as [number, number], zoom: 3.6 };

// Drive time. ORS is used when a key is present, otherwise keyless Valhalla.
export const VALHALLA_URL: string = env.VITE_VALHALLA_URL || 'https://valhalla1.openstreetmap.de';
export const ORS_API_KEY: string | undefined = env.VITE_ORS_API_KEY || undefined;

export const GEOCODER_URL = 'https://nominatim.openstreetmap.org/search';
