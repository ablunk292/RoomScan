// The walkthrough format, as the iPhone app saves it (Swift's default JSON encoding).
// Lengths are meters, dates are seconds since 2001-01-01, ids are UUID strings. Fields this
// editor doesn't know about are kept as they are, because rooms and items are edited in place.

export type Point = { x: number; y: number };
export type Condition = 'good' | 'needsRepair' | 'needsReplacement' | 'outdated';
export type OpeningKind = 'door' | 'window' | 'opening';

export type Item = {
  id: string;
  name: string;
  category: string;
  quantity: number;
  condition: Condition;
  isRequested: boolean;
  notes: string;
  position?: Point;
  dimensions?: { width: number; height: number; depth: number };
  detectedAutomatically: boolean;
  photoFileName?: string;
  parentID?: string;
  [key: string]: unknown;
};

export type Opening = { id: string; kind: OpeningKind; start: Point; end: Point };
export type Measurement = { id: string; name: string; length: number; createdAt: number; notes: string };

export type Room = {
  id: string;
  name: string;
  createdAt: number;
  method: 'cornerTap' | 'lidar';
  outline: Point[];
  ceilingHeight?: number;
  openings: Opening[];
  items: Item[];
  notes: string;
  modelFileName?: string;
  measurements?: Measurement[];
  [key: string]: unknown;
};

export type Property = {
  id: string;
  name: string;
  address: string;
  createdAt: number;
  rooms: Room[];
  notes: string;
  customerName?: string;
  customerEmail?: string;
  customerPhone?: string;
  [key: string]: unknown;
};

export const CATEGORIES = [
  'Appliance', 'Electrical', 'Plumbing', 'HVAC', 'Lighting', 'Furniture',
  'Fixture', 'Network / AV', 'Security', 'Flooring', 'Window / Door', 'Other',
];

export const CONDITIONS: { value: Condition; label: string }[] = [
  { value: 'good', label: 'Good' },
  { value: 'needsRepair', label: 'Needs repair' },
  { value: 'needsReplacement', label: 'Needs replacement' },
  { value: 'outdated', label: 'Outdated' },
];

export const conditionLabel = (c: Condition) => CONDITIONS.find((x) => x.value === c)?.label ?? c;

/** Swift's Date encoding: seconds since 2001-01-01. */
const APPLE_EPOCH = 978307200;
export const nowAppleDate = () => Date.now() / 1000 - APPLE_EPOCH;
export const fromAppleDate = (seconds: number) => new Date((seconds + APPLE_EPOCH) * 1000);

/** Swift writes UUIDs in upper case; match it so ids compare equal on the phone. */
export const newId = () => crypto.randomUUID().toUpperCase();

export function newItem(fields: Partial<Item> = {}): Item {
  return {
    id: newId(),
    name: 'New item',
    category: 'Other',
    quantity: 1,
    condition: 'good',
    isRequested: false,
    notes: '',
    detectedAutomatically: false,
    ...fields,
  };
}

export function newRoom(name: string, origin: Point): Room {
  const w = 3.66; // 12 ft
  return {
    id: newId(),
    name,
    createdAt: nowAppleDate(),
    method: 'cornerTap',
    outline: [
      { x: origin.x, y: origin.y },
      { x: origin.x + w, y: origin.y },
      { x: origin.x + w, y: origin.y + w },
      { x: origin.x, y: origin.y + w },
    ],
    openings: [],
    items: [],
    notes: '',
  };
}

// ── Geometry ────────────────────────────────────────────────────────────────
export function area(outline: Point[]) {
  let sum = 0;
  for (let i = 0; i < outline.length; i++) {
    const a = outline[i];
    const b = outline[(i + 1) % outline.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return Math.abs(sum) / 2;
}

export function perimeter(outline: Point[]) {
  let sum = 0;
  for (let i = 0; i < outline.length; i++) sum += dist(outline[i], outline[(i + 1) % outline.length]);
  return outline.length > 1 ? sum : 0;
}

export const dist = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y);

export function centroid(outline: Point[]): Point {
  if (!outline.length) return { x: 0, y: 0 };
  const sx = outline.reduce((s, p) => s + p.x, 0);
  const sy = outline.reduce((s, p) => s + p.y, 0);
  return { x: sx / outline.length, y: sy / outline.length };
}

export function contains(outline: Point[], p: Point) {
  let inside = false;
  for (let i = 0, j = outline.length - 1; i < outline.length; j = i++) {
    const a = outline[i];
    const b = outline[j];
    if ((a.y > p.y) !== (b.y > p.y) && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}

export function bounds(points: Point[]) {
  if (!points.length) return { minX: 0, minY: 0, maxX: 5, maxY: 5 };
  return {
    minX: Math.min(...points.map((p) => p.x)),
    minY: Math.min(...points.map((p) => p.y)),
    maxX: Math.max(...points.map((p) => p.x)),
    maxY: Math.max(...points.map((p) => p.y)),
  };
}

// ── Units ───────────────────────────────────────────────────────────────────
export function formatLength(m: number, feet: boolean) {
  if (!feet) return `${m.toFixed(2)} m`;
  const totalInches = Math.round(m * 39.3701);
  const ft = Math.floor(totalInches / 12);
  const inches = totalInches % 12;
  return inches ? `${ft}′ ${inches}″` : `${ft}′`;
}

export function formatArea(m2: number, feet: boolean) {
  return feet ? `${Math.round(m2 * 10.7639)} sq ft` : `${m2.toFixed(1)} m²`;
}

/** Parses "12", "12'", "12' 6\"", "12 ft 6 in" or "3.5 m" into meters. */
export function parseLength(text: string, feet: boolean): number | null {
  const t = text.trim().toLowerCase();
  if (!t) return null;
  const metric = t.match(/^([\d.]+)\s*m$/);
  if (metric) return parseFloat(metric[1]);
  const imperial = t.match(/^([\d.]+)\s*(?:'|′|ft)?\s*(?:([\d.]+)\s*(?:"|″|in)?)?$/);
  if (!imperial) return null;
  const a = parseFloat(imperial[1]);
  const b = imperial[2] ? parseFloat(imperial[2]) : 0;
  if (isNaN(a)) return null;
  return feet ? (a * 12 + b) * 0.0254 : a;
}

// ── Items ───────────────────────────────────────────────────────────────────
export type ItemRef = { room: Room; item: Item };

export const allItems = (p: Property): ItemRef[] => p.rooms.flatMap((room) => room.items.map((item) => ({ room, item })));

/** The item and everything stacked on it, at any depth. */
export function itemAndEverythingOn(room: Room, id: string) {
  const found = new Set([id]);
  let added = true;
  while (added) {
    added = false;
    for (const other of room.items) {
      if (!found.has(other.id) && other.parentID && found.has(other.parentID)) {
        found.add(other.id);
        added = true;
      }
    }
  }
  return found;
}
