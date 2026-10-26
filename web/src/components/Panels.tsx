import { useEffect, useState } from 'react';
import {
  area, CATEGORIES, CONDITIONS, formatArea, formatLength, itemAndEverythingOn, newItem, newId, nowAppleDate,
  parseLength, perimeter, dist, type Condition, type Item, type Property, type Room,
} from '../lib/model';
import { photoUrl, uploadPhoto } from '../lib/store';
import type { Selection } from './FloorPlanEditor';

type Update = (change: (draft: Property) => void) => void;

export function Photo({ propertyId, fileName, className }: { propertyId: string; fileName?: string; className?: string }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    setUrl(null);
    if (fileName) photoUrl(propertyId, fileName).then((u) => { if (live) setUrl(u); });
    return () => { live = false; };
  }, [propertyId, fileName]);
  if (!fileName) return null;
  return url
    ? <a href={url} target="_blank" rel="noreferrer"><img src={url} alt="" className={className ?? 'photo'} /></a>
    : <div className={`${className ?? 'photo'} placeholder`}>Photo syncing…</div>;
}

export function ItemPanel({ property, room, item, update, onSelect }: {
  property: Property; room: Room; item: Item; update: Update; onSelect: (s: Selection) => void;
}) {
  const [uploading, setUploading] = useState(false);
  const set = (fields: Partial<Item>) => update((d) => {
    const it = d.rooms.find((r) => r.id === room.id)!.items.find((i) => i.id === item.id)!;
    Object.assign(it, fields);
    for (const [k, val] of Object.entries(fields)) if (val === undefined) delete (it as Record<string, unknown>)[k];
  });
  const blocked = itemAndEverythingOn(room, item.id);
  const parents = room.items.filter((i) => !blocked.has(i.id));
  const onTop = room.items.filter((i) => i.parentID === item.id);

  const remove = () => {
    const extra = onTop.length ? ` The ${onTop.length} item(s) on it stay in the room.` : '';
    if (!confirm(`Delete ${item.name}?${extra}`)) return;
    update((d) => {
      const r = d.rooms.find((x) => x.id === room.id)!;
      r.items = r.items.filter((i) => i.id !== item.id).map((i) => (i.parentID === item.id ? { ...i, parentID: undefined } : i));
      r.items.forEach((i) => { if (i.parentID === undefined) delete i.parentID; });
    });
    onSelect({ kind: 'room', roomId: room.id });
  };

  const addOnTop = () => {
    const child = newItem({ parentID: item.id, position: item.position, isRequested: true, name: 'Requested item' });
    update((d) => { d.rooms.find((r) => r.id === room.id)!.items.push(child); });
    onSelect({ kind: 'item', roomId: room.id, itemId: child.id });
  };

  const upload = async (file?: File) => {
    if (!file) return;
    setUploading(true);
    try {
      const name = await uploadPhoto(property.id, file);
      set({ photoFileName: name });
    } catch (e) {
      alert((e as Error).message);
    } finally {
      setUploading(false);
    }
  };

  return (
    <div className="panel">
      <div className="panel-head">
        <button className="link" onClick={() => onSelect({ kind: 'room', roomId: room.id })}>‹ {room.name}</button>
      </div>
      <Photo propertyId={property.id} fileName={item.photoFileName} />
      <label className="file-button">
        {uploading ? 'Uploading…' : item.photoFileName ? 'Replace photo' : 'Add photo'}
        <input type="file" accept="image/jpeg,image/png" onChange={(e) => upload(e.target.files?.[0])} hidden />
      </label>
      <label>Name<input value={item.name} onChange={(e) => set({ name: e.target.value })} /></label>
      <div className="row">
        <label>Category
          <select value={item.category} onChange={(e) => set({ category: e.target.value })}>
            {CATEGORIES.map((c) => <option key={c}>{c}</option>)}
          </select>
        </label>
        <label className="narrow">Qty
          <input type="number" min={1} value={item.quantity} onChange={(e) => set({ quantity: Math.max(1, parseInt(e.target.value) || 1) })} />
        </label>
      </div>
      <label className="check big">
        <input type="checkbox" checked={item.isRequested} onChange={(e) => set({ isRequested: e.target.checked })} />
        Customer requested (to add or install)
      </label>
      {!item.isRequested && (
        <label>Condition
          <select value={item.condition} onChange={(e) => set({ condition: e.target.value as Condition })}>
            {CONDITIONS.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
          </select>
        </label>
      )}
      <label>Sits on
        <select value={item.parentID ?? ''} onChange={(e) => set({ parentID: e.target.value || undefined })}>
          <option value="">Nothing (on its own)</option>
          {parents.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
      </label>
      <label>Notes<textarea rows={3} value={item.notes} onChange={(e) => set({ notes: e.target.value })} /></label>
      {onTop.length > 0 && (
        <div className="sub">
          <div className="muted small">On this item</div>
          {onTop.map((c) => (
            <button key={c.id} className="list-row" onClick={() => onSelect({ kind: 'item', roomId: room.id, itemId: c.id })}>
              {c.name}{c.isRequested && <span className="badge req">requested</span>}
            </button>
          ))}
        </div>
      )}
      <div className="actions">
        <button onClick={addOnTop}>Add Item on Top</button>
        <button className="danger" onClick={remove}>Delete Item</button>
      </div>
      {item.detectedAutomatically && <p className="muted small">Found by the AI during the scan.</p>}
    </div>
  );
}

export function RoomPanel({ property, room, feet, update, onSelect }: {
  property: Property; room: Room; feet: boolean; update: Update; onSelect: (s: Selection) => void;
}) {
  const set = (change: (r: Room) => void) => update((d) => change(d.rooms.find((r) => r.id === room.id)!));
  const [ceiling, setCeiling] = useState('');
  useEffect(() => { setCeiling(room.ceilingHeight ? formatLength(room.ceilingHeight, feet).replace('′', "'").replace('″', '"') : ''); }, [room.id, room.ceilingHeight, feet]);

  const remove = () => {
    if (!confirm(`Delete ${room.name} and its ${room.items.length} item(s)?`)) return;
    update((d) => { d.rooms = d.rooms.filter((r) => r.id !== room.id); });
    onSelect(null);
  };

  const addMeasurement = () => {
    const name = prompt('What is it? For example "new wall" or "window width".');
    if (!name?.trim()) return;
    const text = prompt(`Length (${feet ? 'like 12\' 6"' : 'like 3.8 m'})`);
    const length = text ? parseLength(text, feet) : null;
    if (!length) return;
    set((r) => { r.measurements = [...(r.measurements ?? []), { id: newId(), name: name.trim(), length, createdAt: nowAppleDate(), notes: '' }]; });
  };

  const walls = room.outline.map((a, i) => dist(a, room.outline[(i + 1) % room.outline.length]));
  const top = room.items.filter((i) => !i.parentID || !room.items.some((p) => p.id === i.parentID));

  return (
    <div className="panel">
      <label>Room name<input value={room.name} onChange={(e) => set((r) => { r.name = e.target.value; })} /></label>
      <div className="facts">
        <div><span className="muted small">Floor area</span>{formatArea(area(room.outline), feet)}</div>
        <div><span className="muted small">Perimeter</span>{formatLength(perimeter(room.outline), feet)}</div>
        <div><span className="muted small">Walls</span>{walls.length}</div>
      </div>
      <label>Ceiling height
        <input
          value={ceiling}
          placeholder={feet ? `8'` : '2.44 m'}
          onChange={(e) => setCeiling(e.target.value)}
          onBlur={() => {
            const h = parseLength(ceiling, feet);
            set((r) => { if (h) r.ceilingHeight = h; else delete r.ceilingHeight; });
          }}
        />
      </label>
      {room.ceilingHeight && (
        <div className="muted small">Wall area about {formatArea(perimeter(room.outline) * room.ceilingHeight, feet)} before doors and windows.</div>
      )}
      <div className="sub">
        <div className="muted small">Wall lengths (click a length on the plan to change it)</div>
        <div className="chips">{walls.map((w, i) => <span key={i} className="chip">{i + 1}: {formatLength(w, feet)}</span>)}</div>
      </div>
      <div className="sub">
        <div className="sub-head"><span className="muted small">Measurements</span><button className="link" onClick={addMeasurement}>Add</button></div>
        {(room.measurements ?? []).map((m) => (
          <div key={m.id} className="list-row static">
            <span>{m.name}</span><span className="spacer" /><span>{formatLength(m.length, feet)}</span>
            <button className="link danger" onClick={() => set((r) => { r.measurements = (r.measurements ?? []).filter((x) => x.id !== m.id); if (!r.measurements.length) delete r.measurements; })}>✕</button>
          </div>
        ))}
        {!(room.measurements ?? []).length && <div className="muted small">None saved.</div>}
      </div>
      <div className="sub">
        <div className="muted small">Items ({room.items.length})</div>
        {top.map((i) => (
          <button key={i.id} className="list-row" onClick={() => onSelect({ kind: 'item', roomId: room.id, itemId: i.id })}>
            <span>{i.name}{i.quantity > 1 ? ` ×${i.quantity}` : ''}</span>
            {i.isRequested && <span className="badge req">requested</span>}
            {room.items.some((c) => c.parentID === i.id) && <span className="muted small">+{room.items.filter((c) => c.parentID === i.id).length} on it</span>}
          </button>
        ))}
        {!room.items.length && <div className="muted small">No items. Use + Item on the plan.</div>}
      </div>
      <label>Notes<textarea rows={3} value={room.notes} onChange={(e) => set((r) => { r.notes = e.target.value; })} /></label>
      <div className="actions">
        <button className="danger" onClick={remove}>Delete Room</button>
      </div>
      <p className="muted small">{property.rooms.length} room(s) in this walkthrough.</p>
    </div>
  );
}

export function PropertyPanel({ property, update }: { property: Property; update: Update }) {
  const set = (fields: Partial<Property>) => update((d) => { Object.assign(d, fields); });
  return (
    <div className="panel">
      <p className="muted small">Select a room or item on the plan to edit it.</p>
      <label>Walkthrough name<input value={property.name} onChange={(e) => set({ name: e.target.value })} /></label>
      <label>Address<input value={property.address} onChange={(e) => set({ address: e.target.value })} /></label>
      <label>Customer<input value={property.customerName ?? ''} onChange={(e) => set({ customerName: e.target.value })} /></label>
      <div className="row">
        <label>Email<input value={property.customerEmail ?? ''} onChange={(e) => set({ customerEmail: e.target.value })} /></label>
        <label>Phone<input value={property.customerPhone ?? ''} onChange={(e) => set({ customerPhone: e.target.value })} /></label>
      </div>
      <label>Notes<textarea rows={4} value={property.notes} onChange={(e) => set({ notes: e.target.value })} /></label>
    </div>
  );
}
