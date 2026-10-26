import { useEffect, useState } from 'react';
import { Link, NavLink, Route, Routes, useNavigate, useParams } from 'react-router-dom';
import { useWalkthrough } from '../lib/useWalkthrough';
import { useUnits } from '../lib/units';
import { allItems, area, formatArea } from '../lib/model';
import { quoteLinks } from '../lib/quotemaster';
import { QUOTEMASTER_URL } from '../lib/supabase';
import FloorPlanEditor, { type Selection } from '../components/FloorPlanEditor';
import { ItemPanel, PropertyPanel, RoomPanel } from '../components/Panels';
import ItemsTable from '../components/ItemsTable';
import ExportPanel from '../components/ExportPanel';
import AIHelper from '../components/AIHelper';
import QuoteWizard from '../components/QuoteWizard';

const SAVE_LABEL = { saved: 'All changes saved', unsaved: 'Unsaved changes…', saving: 'Saving…', error: 'Not saved', stale: 'Changed elsewhere' };

export default function Walkthrough() {
  const { id = '' } = useParams();
  const w = useWalkthrough(id);
  const [feet, setFeet] = useUnits();
  const [selection, setSelection] = useState<Selection>(null);
  const [aiOpen, setAiOpen] = useState(false);
  const [wizardOpen, setWizardOpen] = useState(false);
  const [links, setLinks] = useState<Awaited<ReturnType<typeof quoteLinks>>>([]);
  const navigate = useNavigate();

  useEffect(() => { quoteLinks(id).then(setLinks); }, [id, wizardOpen]);

  if (w.loadError) return <main className="page"><div className="error">{w.loadError}</div><Link to="/">Back to walkthroughs</Link></main>;
  const p = w.property;
  if (!p) return <main className="page muted">Loading…</main>;

  // Drop a selection whose room or item was deleted (for example by undo).
  const room = selection ? p.rooms.find((r) => r.id === selection.roomId) : undefined;
  const item = selection?.kind === 'item' ? room?.items.find((i) => i.id === selection.itemId) : undefined;

  const items = allItems(p);
  const openOnPlan = (s: Selection) => { setSelection(s); navigate(`/w/${id}`); };

  return (
    <div className="walkthrough">
      <div className="w-head no-print">
        <div>
          <Link to="/" className="muted small">‹ Walkthroughs</Link>
          <h1>{p.name}</h1>
          <div className="muted small">
            {p.rooms.length} rooms · {formatArea(p.rooms.reduce((s, r) => s + area(r.outline), 0), feet)} · {items.length} items · {items.filter((r) => r.item.isRequested).length} requested
          </div>
        </div>
        <span className="spacer" />
        <span className={`save ${w.saveState}`}>{SAVE_LABEL[w.saveState]}</span>
        <button className="ghost" disabled={!w.canUndo} onClick={w.undo} title="Undo (Ctrl+Z)">↶</button>
        <button className="ghost" disabled={!w.canRedo} onClick={w.redo} title="Redo (Ctrl+Shift+Z)">↷</button>
        <div className="segmented">
          <button className={feet ? 'on' : ''} onClick={() => setFeet(true)}>ft</button>
          <button className={!feet ? 'on' : ''} onClick={() => setFeet(false)}>m</button>
        </div>
        <button onClick={() => setAiOpen(!aiOpen)}>✨ AI Helper</button>
        <button className="primary" onClick={() => setWizardOpen(true)}>Send to QuoteMaster</button>
      </div>
      {(w.saveState === 'stale' || w.saveState === 'error') && (
        <div className="banner warn no-print">
          {w.saveError}{' '}
          {w.saveState === 'stale' ? <button className="link" onClick={w.reload}>Reload latest (your unsaved edits are dropped)</button>
            : <button className="link" onClick={w.saveNow}>Try again</button>}
        </div>
      )}
      {links.length > 0 && (
        <div className="banner info no-print">
          Quotes made from this walkthrough:{' '}
          {links.map((l) => (
            <a key={l.quote_id} href={`${QUOTEMASTER_URL}/QuoteEditor?id=${l.quote_id}`} target="_blank" rel="noreferrer" className="quote-link">
              {l.quote?.quote_number ?? 'Quote'} ({l.quote?.status ?? 'deleted'})
            </a>
          ))}
        </div>
      )}
      <nav className="tabs no-print">
        <NavLink end to={`/w/${id}`}>Floor plan</NavLink>
        <NavLink to={`/w/${id}/items`}>Items ({items.length})</NavLink>
        <NavLink to={`/w/${id}/export`}>Export</NavLink>
      </nav>
      <div className={`w-body ${aiOpen ? 'with-ai' : ''}`}>
        <div className="w-main">
          <Routes>
            <Route index element={
              <div className="plan-layout">
                <FloorPlanEditor property={p} feet={feet} selection={room ? selection : null} onSelect={setSelection} update={w.update} checkpoint={w.checkpoint} />
                <div className="side">
                  {room && item && <ItemPanel property={p} room={room} item={item} update={w.update} onSelect={setSelection} />}
                  {room && !item && <RoomPanel property={p} room={room} feet={feet} update={w.update} onSelect={setSelection} />}
                  {!room && <PropertyPanel property={p} update={w.update} />}
                </div>
              </div>
            } />
            <Route path="items" element={<ItemsTable property={p} update={w.update} onOpen={openOnPlan} />} />
            <Route path="export" element={<ExportPanel property={p} feet={feet} />} />
          </Routes>
        </div>
        {aiOpen && <AIHelper property={p} update={w.update} onClose={() => setAiOpen(false)} />}
      </div>
      {wizardOpen && <QuoteWizard property={p} onClose={() => setWizardOpen(false)} />}
    </div>
  );
}
