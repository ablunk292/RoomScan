import { useMemo, useState } from 'react';
import { allItems, CATEGORIES, CONDITIONS, conditionLabel, type Condition, type Item, type Property } from '../lib/model';
import { Photo } from './Panels';
import type { Selection } from './FloorPlanEditor';

type Kind = 'all' | 'existing' | 'requested';

export default function ItemsTable({ property, update, onOpen }: {
  property: Property;
  update: (change: (draft: Property) => void) => void;
  onOpen: (s: Selection) => void;
}) {
  const [search, setSearch] = useState('');
  const [categories, setCategories] = useState<Set<string>>(new Set());
  const [conditions, setConditions] = useState<Set<Condition>>(new Set());
  const [rooms, setRooms] = useState<Set<string>>(new Set());
  const [kind, setKind] = useState<Kind>('all');
  const [aiOnly, setAiOnly] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const refs = allItems(property);
  const shown = useMemo(() => refs.filter(({ room, item }) => {
    if (categories.size && !categories.has(item.category)) return false;
    if (conditions.size && (item.isRequested || !conditions.has(item.condition))) return false;
    if (rooms.size && !rooms.has(room.id)) return false;
    if (kind === 'existing' && item.isRequested) return false;
    if (kind === 'requested' && !item.isRequested) return false;
    if (aiOnly && !item.detectedAutomatically) return false;
    const q = search.trim().toLowerCase();
    return !q || [item.name, item.notes, item.category, room.name].some((s) => s.toLowerCase().includes(q));
  }), [refs, categories, conditions, rooms, kind, aiOnly, search]);

  const filtered = categories.size || conditions.size || rooms.size || kind !== 'all' || aiOnly || search;
  const toggle = <T,>(set: Set<T>, value: T, apply: (s: Set<T>) => void) => {
    const next = new Set(set);
    if (next.has(value)) next.delete(value); else next.add(value);
    apply(next);
  };
  const clear = () => { setCategories(new Set()); setConditions(new Set()); setRooms(new Set()); setKind('all'); setAiOnly(false); setSearch(''); };

  const selectedShown = shown.filter((r) => selected.has(r.item.id));
  const allShownSelected = shown.length > 0 && selectedShown.length === shown.length;

  const editSelected = (change: (item: Item) => void) => update((d) => {
    d.rooms.forEach((r) => r.items.forEach((i) => { if (selected.has(i.id)) change(i); }));
  });

  const moveSelected = (roomId: string) => update((d) => {
    const target = d.rooms.find((r) => r.id === roomId);
    if (!target) return;
    for (const r of d.rooms) {
      if (r.id === roomId) continue;
      const moving = r.items.filter((i) => selected.has(i.id));
      r.items = r.items.filter((i) => !selected.has(i.id));
      // Items left behind can't sit on something that moved away.
      r.items.forEach((i) => { if (i.parentID && !r.items.some((p) => p.id === i.parentID)) delete i.parentID; });
      moving.forEach((i) => {
        if (i.parentID && !moving.some((p) => p.id === i.parentID)) delete i.parentID;
        delete i.position;
      });
      target.items.push(...moving);
    }
  });

  const deleteSelected = () => {
    if (!confirm(`Delete ${selected.size} item(s)? Items sitting on them stay.`)) return;
    update((d) => d.rooms.forEach((r) => {
      r.items = r.items.filter((i) => !selected.has(i.id));
      r.items.forEach((i) => { if (i.parentID && selected.has(i.parentID)) delete i.parentID; });
    }));
    setSelected(new Set());
  };

  const setField = (roomId: string, itemId: string, fields: Partial<Item>) => update((d) => {
    Object.assign(d.rooms.find((r) => r.id === roomId)!.items.find((i) => i.id === itemId)!, fields);
  });

  const usedCategories = CATEGORIES.filter((c) => refs.some((r) => r.item.category === c));

  return (
    <div className="items">
      <div className="filters">
        <input className="search" placeholder="Search items" value={search} onChange={(e) => setSearch(e.target.value)} />
        <div className="segmented">
          {(['all', 'existing', 'requested'] as Kind[]).map((k) => (
            <button key={k} className={kind === k ? 'on' : ''} onClick={() => setKind(k)}>
              {k === 'all' ? 'All' : k === 'existing' ? 'Existing' : 'Requested'}
            </button>
          ))}
        </div>
        <label className="check"><input type="checkbox" checked={aiOnly} onChange={(e) => setAiOnly(e.target.checked)} /> Found by AI</label>
        {filtered && <button className="link" onClick={clear}>Clear filters</button>}
      </div>
      <div className="chip-row">
        <span className="muted small">Category</span>
        {usedCategories.map((c) => (
          <button key={c} className={`chip ${categories.has(c) ? 'on' : ''}`} onClick={() => toggle(categories, c, setCategories)}>{c}</button>
        ))}
      </div>
      <div className="chip-row">
        <span className="muted small">Condition</span>
        {CONDITIONS.map((c) => (
          <button key={c.value} className={`chip ${conditions.has(c.value) ? 'on' : ''}`} onClick={() => toggle(conditions, c.value, setConditions)}>{c.label}</button>
        ))}
        <span className="muted small">Room</span>
        {property.rooms.map((r) => (
          <button key={r.id} className={`chip ${rooms.has(r.id) ? 'on' : ''}`} onClick={() => toggle(rooms, r.id, setRooms)}>{r.name}</button>
        ))}
      </div>

      {selected.size > 0 && (
        <div className="bulk">
          <strong>{selected.size} selected</strong>
          <select value="" onChange={(e) => { if (e.target.value) editSelected((i) => { i.category = e.target.value; }); }}>
            <option value="">Set category…</option>
            {CATEGORIES.map((c) => <option key={c}>{c}</option>)}
          </select>
          <select value="" onChange={(e) => { if (e.target.value) editSelected((i) => { i.condition = e.target.value as Condition; }); }}>
            <option value="">Set condition…</option>
            {CONDITIONS.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
          </select>
          <button onClick={() => editSelected((i) => { i.isRequested = true; })}>Mark Requested</button>
          <button onClick={() => editSelected((i) => { i.isRequested = false; })}>Mark Existing</button>
          <select value="" onChange={(e) => { if (e.target.value) moveSelected(e.target.value); }}>
            <option value="">Move to room…</option>
            {property.rooms.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
          </select>
          <button className="danger" onClick={deleteSelected}>Delete</button>
          <button className="link" onClick={() => setSelected(new Set())}>Deselect</button>
        </div>
      )}

      <table className="table">
        <thead>
          <tr>
            <th><input type="checkbox" checked={allShownSelected} onChange={() => {
              const next = new Set(selected);
              shown.forEach((r) => (allShownSelected ? next.delete(r.item.id) : next.add(r.item.id)));
              setSelected(next);
            }} /></th>
            <th></th>
            <th>Item</th>
            <th>Room</th>
            <th>Category</th>
            <th>Qty</th>
            <th>Condition / request</th>
            <th>Notes</th>
          </tr>
        </thead>
        <tbody>
          {shown.map(({ room, item }) => {
            const parent = item.parentID ? room.items.find((i) => i.id === item.parentID) : undefined;
            return (
              <tr key={item.id} className={selected.has(item.id) ? 'sel' : ''}>
                <td><input type="checkbox" checked={selected.has(item.id)} onChange={() => toggle(selected, item.id, setSelected)} /></td>
                <td><Photo propertyId={property.id} fileName={item.photoFileName} className="thumb" /></td>
                <td>
                  <input className="cell" value={item.name} onChange={(e) => setField(room.id, item.id, { name: e.target.value })} />
                  {parent && <div className="muted small">on {parent.name}</div>}
                </td>
                <td><button className="link" onClick={() => onOpen({ kind: 'item', roomId: room.id, itemId: item.id })}>{room.name}</button></td>
                <td>
                  <select className="cell" value={item.category} onChange={(e) => setField(room.id, item.id, { category: e.target.value })}>
                    {CATEGORIES.map((c) => <option key={c}>{c}</option>)}
                  </select>
                </td>
                <td><input className="cell qty" type="number" min={1} value={item.quantity} onChange={(e) => setField(room.id, item.id, { quantity: Math.max(1, parseInt(e.target.value) || 1) })} /></td>
                <td>{item.isRequested ? <span className="badge req">Requested</span> : conditionLabel(item.condition)}</td>
                <td><input className="cell" value={item.notes} onChange={(e) => setField(room.id, item.id, { notes: e.target.value })} /></td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {!shown.length && <p className="muted center">{refs.length ? 'No items match these filters.' : 'No items yet.'}</p>}
      <p className="muted small">Showing {shown.length} of {refs.length} items.</p>
    </div>
  );
}
