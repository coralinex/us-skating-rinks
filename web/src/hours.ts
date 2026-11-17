// Opening-hours evaluation. Everything is computed from tile properties
// (`opening_hours`, `hours_status`) plus the feature's coordinates, so it
// behaves identically against PMTiles and a live tile server.
import OpeningHours from 'opening_hours';
import tzlookup from 'tz-lookup';

export type HoursState = 'open' | 'closed' | 'unknown';

export type HoursQuery =
  | { mode: 'any' }
  | { mode: 'now' }
  | { mode: 'at'; day: number; time: string }; // day: 0=Sun..6=Sat, time: "HH:MM"

const parsed = new Map<string, OpeningHours | null>();

function parse(raw: string, lat: number, lon: number): OpeningHours | null {
  // Holidays / sunrise depend on location; a 1° cell is plenty for that.
  const key = `${raw}|${Math.round(lat)}|${Math.round(lon)}`;
  let oh = parsed.get(key);
  if (oh === undefined) {
    try {
      oh = new OpeningHours(raw, { lat: String(lat), lon: String(lon), address: { country_code: 'us', state: '' } });
    } catch {
      try {
        oh = new OpeningHours(raw);
      } catch {
        oh = null; // unparseable => treated as unknown, never as closed
      }
    }
    parsed.set(key, oh);
  }
  return oh;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

/**
 * A Date whose *local* fields (getHours(), getDay(), ...) equal the wall
 * clock at the given coordinates. opening_hours reads local fields, so this
 * is how "open now" is evaluated in the rink's timezone, not the viewer's.
 */
export function wallClockAt(lat: number, lon: number, instant: Date): Date {
  let tz: string;
  try {
    tz = tzlookup(lat, lon);
  } catch {
    return instant;
  }
  let fmt = formatters.get(tz);
  if (!fmt) {
    fmt = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23',
      year: 'numeric', month: 'numeric', day: 'numeric',
      hour: 'numeric', minute: 'numeric', second: 'numeric',
    });
    formatters.set(tz, fmt);
  }
  const p: Record<string, number> = {};
  for (const part of fmt.formatToParts(instant)) {
    if (part.type !== 'literal') p[part.type] = Number(part.value);
  }
  return new Date(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
}

/** The wall-clock moment a query refers to, for a rink at lat/lon. */
export function queryMoment(q: HoursQuery, lat: number, lon: number, now = new Date()): Date {
  const local = wallClockAt(lat, lon, now);
  if (q.mode !== 'at') return local;
  const [h, m] = q.time.split(':').map(Number);
  const d = new Date(local.getFullYear(), local.getMonth(), local.getDate(), h || 0, m || 0, 0);
  // Next occurrence of that weekday at that time (today counts if not yet past).
  let add = (q.day - d.getDay() + 7) % 7;
  if (add === 0 && d < local) add = 7;
  d.setDate(d.getDate() + add);
  return d;
}

export function hoursState(raw: string | undefined | null, lat: number, lon: number, at: Date): HoursState {
  if (!raw) return 'unknown';
  const oh = parse(raw, lat, lon);
  if (!oh) return 'unknown';
  try {
    if (oh.getUnknown(at)) return 'unknown';
    return oh.getState(at) ? 'open' : 'closed';
  } catch {
    return 'unknown';
  }
}

/** Human-readable details for the popup. */
export function describeHours(raw: string | undefined | null, lat: number, lon: number): {
  state: HoursState; label: string; pretty?: string;
} {
  if (!raw) return { state: 'unknown', label: 'Hours not listed' };
  const oh = parse(raw, lat, lon);
  if (!oh) return { state: 'unknown', label: 'Hours listed but not machine-readable', pretty: raw };
  const now = wallClockAt(lat, lon, new Date());
  const state = hoursState(raw, lat, lon, now);
  let label = state === 'open' ? 'Open now' : state === 'closed' ? 'Closed now' : 'Hours uncertain right now';
  try {
    const next = oh.getNextChange(now);
    if (next && state !== 'unknown') {
      const sameDay = next.toDateString() === now.toDateString();
      const when = next.toLocaleString('en-US', sameDay
        ? { hour: 'numeric', minute: '2-digit' }
        : { weekday: 'short', hour: 'numeric', minute: '2-digit' });
      label += state === 'open' ? ` · closes ${when}` : ` · opens ${when}`;
    }
  } catch { /* next change is a nicety */ }
  let pretty = raw;
  try { pretty = oh.prettifyValue(); } catch { /* keep raw */ }
  return { state, label, pretty };
}
