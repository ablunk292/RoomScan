import { useState } from 'react';
import {
  area, bounds, centroid, conditionLabel, formatArea, formatLength, fromAppleDate, perimeter,
  type Item, type Property, type Room,
} from '../lib/model';
import { Photo, } from './Panels';
import { categoryColor } from './FloorPlanEditor';

type ExistingChoice = 'all' | 'work' | 'none';

export type ExportOptions = {
  roomIds: Set<string>;
  existing: ExistingChoice;
  requested: boolean;
  photos: boolean;
  plan: boolean;
};

export function filterItems(room: Room, o: ExportOptions): Item[] {
  return room.items.filter((i) => {
    if (i.isRequested) return o.requested;
    if (o.existing === 'none') return false;
    if (o.existing === 'work') return i.condition !== 'good';
    return true;
  });
}

export default function ExportPanel({ property, feet }: { property: Property; feet: boolean }) {
  const [options, setOptions] = useState<ExportOptions>({
    roomIds: new Set(property.rooms.map((r) => r.id)), existing: 'all', requested: true, photos: true, plan: true,
  });
  const set = (fields: Partial<ExportOptions>) => setOptions((o) => ({ ...o, ...fields }));
  const rooms = property.rooms.filter((r) => options.roomIds.has(r.id));
  const count = rooms.reduce((s, r) => s + filterItems(r, options).length, 0);

  const downloadCSV = () => {
    const rows = [['Room', 'Item', 'Category', 'Quantity', 'Customer requested', 'Condition', 'On top of', 'Notes', 'Found by AI']];
    for (const room of rooms) {
      for (const i of filterItems(room, options)) {
        const parent = i.parentID ? room.items.find((p) => p.id === i.parentID)?.name ?? '' : '';
        rows.push([room.name, i.name, i.category, String(i.quantity), i.isRequested ? 'Yes' : 'No',
          i.isRequested ? '' : conditionLabel(i.condition), parent, i.notes, i.detectedAutomatically ? 'Yes' : 'No']);
      }
    }
    rows.push([]);
    rows.push(['Room', 'Floor area', 'Perimeter', 'Ceiling height', 'Measurement', 'Length']);
    for (const room of rooms) {
      rows.push([room.name, formatArea(area(room.outline), feet), formatLength(perimeter(room.outline), feet),
        room.ceilingHeight ? formatLength(room.ceilingHeight, feet) : '', '', '']);
      for (const m of room.measurements ?? []) rows.push([room.name, '', '', '', m.name, formatLength(m.length, feet)]);
    }
    const csv = rows.map((r) => r.map((c) => `"${String(c ?? '').replace(/"/g, '""')}"`).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `${property.name.replace(/[^\w -]+/g, '')} items.csv`;
    a.click();
    URL.revokeObjectURL(a.href);
  };

  return (
    <div className="export">
      <div className="card export-options no-print">
        <h3>What to include</h3>
        <div className="chip-row">
          <span className="muted small">Rooms</span>
          {property.rooms.map((r) => (
            <button key={r.id} className={`chip ${options.roomIds.has(r.id) ? 'on' : ''}`} onClick={() => {
              const next = new Set(options.roomIds);
              if (next.has(r.id)) next.delete(r.id); else next.add(r.id);
              set({ roomIds: next });
            }}>{r.name}</button>
          ))}
        </div>
        <div className="row wrap">
          <label>Existing items
            <select value={options.existing} onChange={(e) => set({ existing: e.target.value as ExistingChoice })}>
              <option value="all">All existing items</option>
              <option value="work">Only ones needing work</option>
              <option value="none">None</option>
            </select>
          </label>
          <label className="check"><input type="checkbox" checked={options.requested} onChange={(e) => set({ requested: e.target.checked })} /> Customer requests</label>
          <label className="check"><input type="checkbox" checked={options.photos} onChange={(e) => set({ photos: e.target.checked })} /> Photos</label>
          <label className="check"><input type="checkbox" checked={options.plan} onChange={(e) => set({ plan: e.target.checked })} /> Floor plan</label>
        </div>
        <div className="actions">
          <button className="primary" onClick={() => window.print()} disabled={!rooms.length}>Print or Save as PDF</button>
          <button onClick={downloadCSV} disabled={!rooms.length}>Download Spreadsheet (CSV)</button>
          <span className="muted small">{rooms.length} room(s), {count} item(s)</span>
        </div>
      </div>
      <Report property={property} rooms={rooms} options={options} feet={feet} />
    </div>
  );
}

function Report({ property, rooms, options, feet }: { property: Property; rooms: Room[]; options: ExportOptions; feet: boolean }) {
  const total = rooms.reduce((s, r) => s + area(r.outline), 0);
  return (
    <div className="report card">
      <h1>{property.name}</h1>
      {property.address && <div>{property.address}</div>}
      {property.customerName && <div>Customer: {property.customerName}{property.customerEmail ? `, ${property.customerEmail}` : ''}{property.customerPhone ? `, ${property.customerPhone}` : ''}</div>}
      <div className="muted small">Walkthrough started {fromAppleDate(property.createdAt).toLocaleDateString()} · {rooms.length} rooms · {formatArea(total, feet)}</div>
      {property.notes && <p>{property.notes}</p>}
      {options.plan && rooms.length > 0 && <StaticPlan rooms={rooms} feet={feet} />}
      {rooms.map((room) => {
        const items = filterItems(room, options);
        return (
          <section key={room.id} className="report-room">
            <h2>{room.name}</h2>
            <div className="muted small">
              {formatArea(area(room.outline), feet)} · perimeter {formatLength(perimeter(room.outline), feet)}
              {room.ceilingHeight ? ` · ceiling ${formatLength(room.ceilingHeight, feet)}` : ''}
              {room.openings.length ? ` · ${room.openings.filter((o) => o.kind === 'door').length} doors, ${room.openings.filter((o) => o.kind === 'window').length} windows` : ''}
            </div>
            {room.notes && <p>{room.notes}</p>}
            {items.length > 0 && (
              <table className="table">
                <thead><tr>{options.photos && <th></th>}<th>Item</th><th>Category</th><th>Qty</th><th>Status</th><th>Notes</th></tr></thead>
                <tbody>
                  {items.map((i) => {
                    const parent = i.parentID ? room.items.find((p) => p.id === i.parentID) : undefined;
                    return (
                      <tr key={i.id}>
                        {options.photos && <td><Photo propertyId={property.id} fileName={i.photoFileName} className="thumb" /></td>}
                        <td>{i.name}{parent && <div className="muted small">on {parent.name}</div>}</td>
                        <td>{i.category}</td>
                        <td>{i.quantity}</td>
                        <td>{i.isRequested ? 'Customer request' : conditionLabel(i.condition)}</td>
                        <td>{i.notes}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
            {(room.measurements ?? []).length > 0 && (
              <div className="small">Measurements: {(room.measurements ?? []).map((m) => `${m.name} ${formatLength(m.length, feet)}`).join(' · ')}</div>
            )}
          </section>
        );
      })}
    </div>
  );
}

export function StaticPlan({ rooms, feet, height = 320 }: { rooms: Room[]; feet: boolean; height?: number }) {
  const b = bounds(rooms.flatMap((r) => r.outline));
  const pad = 0.8;
  const w = b.maxX - b.minX + pad * 2;
  const h = b.maxY - b.minY + pad * 2;
  const tx = (x: number) => x - b.minX + pad;
  const ty = (y: number) => y - b.minY + pad;
  const font = Math.max(w, h) / 45;
  return (
    <svg className="static-plan" viewBox={`0 0 ${w} ${h}`} style={{ maxHeight: height }}>
      {rooms.map((room) => {
        const c = centroid(room.outline);
        return (
          <g key={room.id}>
            <polygon points={room.outline.map((p) => `${tx(p.x)},${ty(p.y)}`).join(' ')} fill="rgba(37,99,235,0.06)" stroke="#334155" strokeWidth={font / 5} />
            {room.openings.map((o) => (
              <line key={o.id} x1={tx(o.start.x)} y1={ty(o.start.y)} x2={tx(o.end.x)} y2={ty(o.end.y)}
                stroke={o.kind === 'window' ? '#0ea5e9' : o.kind === 'door' ? '#b45309' : '#f8fafc'} strokeWidth={font / 2.5} />
            ))}
            {room.items.map((i) => i.position && (
              <circle key={i.id} cx={tx(i.position.x)} cy={ty(i.position.y)} r={font / 2.6}
                fill={i.isRequested ? '#fff' : categoryColor(i.category)} stroke={i.isRequested ? '#dc2626' : 'none'} strokeWidth={font / 6} />
            ))}
            <text x={tx(c.x)} y={ty(c.y)} fontSize={font} textAnchor="middle" fill="#0f172a">{room.name}</text>
            <text x={tx(c.x)} y={ty(c.y) + font * 1.2} fontSize={font * 0.8} textAnchor="middle" fill="#475569">{formatArea(area(room.outline), feet)}</text>
          </g>
        );
      })}
    </svg>
  );
}
