import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { createProperty, deleteProperty, listProperties, type PropertyRow } from '../lib/store';
import { allItems, area, formatArea, newId, nowAppleDate, type Property } from '../lib/model';
import { useUnits } from '../lib/units';

export default function Walkthroughs() {
  const [rows, setRows] = useState<PropertyRow[] | null>(null);
  const [error, setError] = useState('');
  const [query, setQuery] = useState('');
  const [feet] = useUnits();
  const navigate = useNavigate();

  const load = () => listProperties().then(setRows).catch((e) => setError(e.message));
  useEffect(() => { load(); }, []);

  const create = async () => {
    const name = prompt('Name the property, such as the address or the customer.');
    if (!name?.trim()) return;
    const property: Property = { id: newId(), name: name.trim(), address: '', createdAt: nowAppleDate(), rooms: [], notes: '' };
    try {
      await createProperty(property);
      navigate(`/w/${property.id}`);
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const remove = async (row: PropertyRow) => {
    if (!confirm(`Delete "${row.name}"? It is removed from the web and from phones when they sync.`)) return;
    await deleteProperty(row.id);
    load();
  };

  const shown = (rows ?? []).filter((r) => {
    const q = query.trim().toLowerCase();
    if (!q) return true;
    return [r.name, r.data.address, r.data.customerName].some((s) => String(s ?? '').toLowerCase().includes(q));
  });

  return (
    <main className="page">
      <div className="page-head">
        <h1>Walkthroughs</h1>
        <span className="spacer" />
        <input className="search" placeholder="Search" value={query} onChange={(e) => setQuery(e.target.value)} />
        <button className="primary" onClick={create}>New Walkthrough</button>
      </div>
      {error && <div className="error">{error}</div>}
      {rows === null && <p className="muted">Loading…</p>}
      {rows && rows.length === 0 && (
        <div className="empty card">
          <h2>No walkthroughs yet</h2>
          <p className="muted">
            Map a property with the RoomScan app on your iPhone and sign in there with this account.
            It syncs here automatically. You can also start one here and draw the rooms yourself.
          </p>
        </div>
      )}
      <div className="grid">
        {shown.map((row) => {
          const p = row.data;
          const items = allItems(p);
          const requested = items.filter((r) => r.item.isRequested).length;
          const total = p.rooms.reduce((s, r) => s + area(r.outline), 0);
          return (
            <div key={row.id} className="card tile">
              <Link to={`/w/${row.id}`} className="tile-link">
                <h3>{row.name}</h3>
                {p.address && <div className="muted small">{p.address}</div>}
                {p.customerName && <div className="small">Customer: {p.customerName}</div>}
                <div className="stats">
                  <span>{p.rooms.length} room{p.rooms.length === 1 ? '' : 's'}</span>
                  <span>{formatArea(total, feet)}</span>
                  <span>{items.length} items</span>
                  {requested > 0 && <span className="badge req">{requested} requested</span>}
                </div>
                <div className="muted small">Updated {new Date(row.updated_at).toLocaleString()}</div>
              </Link>
              <button className="ghost small danger" onClick={() => remove(row)}>Delete</button>
            </div>
          );
        })}
      </div>
    </main>
  );
}
