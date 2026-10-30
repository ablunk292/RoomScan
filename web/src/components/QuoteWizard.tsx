import { useEffect, useMemo, useState } from 'react';
import { conditionLabel, type Property } from '../lib/model';
import { callAI, QUOTEMASTER_URL } from '../lib/supabase';
import {
  createQuote, CRM_STAGES, LEAD_SOURCES, linesFor, loadProducts, loadTemplates, searchClients, totals,
  type Client, type Line, type Product, type Template,
} from '../lib/quotemaster';

const STEPS = ['Items', 'Client', 'Opportunity', 'Look', 'Products & prices', 'Review'];
const money = (n: number) => n.toLocaleString('en-US', { style: 'currency', currency: 'USD' });

type Match = { item_id: string; product_id: string; confidence: string; reason: string; estimated_unit_price: number; estimated_unit_cost: number };

export default function QuoteWizard({ property, onClose }: { property: Property; onClose: () => void }) {
  const [step, setStep] = useState(0);
  const [error, setError] = useState('');

  // Step 1: items
  const [chosen, setChosen] = useState<Set<string>>(() => new Set(
    property.rooms.flatMap((r) => r.items.filter((i) => i.isRequested).map((i) => i.id)),
  ));
  const [combine, setCombine] = useState(true);
  const [groupByRoom, setGroupByRoom] = useState(true);

  // Step 2: client
  const [clientQuery, setClientQuery] = useState(property.customerName ?? '');
  const [clients, setClients] = useState<Client[]>([]);
  const [client, setClient] = useState({
    existingId: '', saveNew: true,
    name: property.customerName ?? '', email: property.customerEmail ?? '', company: '', phone: property.customerPhone ?? '',
    address: property.address ?? '', city: '', state: '', zip: '', taxRate: 0, taxExempt: false,
  });

  // Step 3: opportunity
  const [title, setTitle] = useState(property.name);
  const [stage, setStage] = useState('proposal');
  const [leadSource, setLeadSource] = useState('');
  const [probability, setProbability] = useState('');
  const [salesNotes, setSalesNotes] = useState('');

  // Step 4: look
  const [templates, setTemplates] = useState<Template[] | null>(null);
  const [templateId, setTemplateId] = useState('');

  // Step 5: products and prices
  const [products, setProducts] = useState<Product[]>([]);
  const [lines, setLines] = useState<Line[]>([]);
  const [matching, setMatching] = useState(false);
  const [matchedFor, setMatchedFor] = useState('');

  // Step 6
  const [creating, setCreating] = useState(false);
  const [createdId, setCreatedId] = useState('');
  const [notes, setNotes] = useState(`Prepared from the RoomScan walkthrough "${property.name}".`);

  useEffect(() => {
    loadTemplates().then((t) => {
      setTemplates(t);
      const def = t.find((x) => x.is_default);
      if (def) setTemplateId(def.id);
    }).catch((e) => setError(e.message));
    loadProducts().then(setProducts).catch((e) => setError(e.message));
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => searchClients(clientQuery).then(setClients).catch(() => setClients([])), 250);
    return () => clearTimeout(timer);
  }, [clientQuery]);

  const productMap = useMemo(() => new Map(products.map((p) => [p.id, p])), [products]);
  const rooms = property.rooms.filter((r) => r.items.some((i) => chosen.has(i.id)));

  // Build lines when entering the pricing step, and ask the AI for product matches once per item choice.
  const chosenKey = [...chosen].sort().join(',') + `|${combine}`;
  useEffect(() => {
    if (step !== 4 || matchedFor === chosenKey) return;
    const fresh = linesFor(property.rooms, chosen, combine);
    setLines(fresh);
    setMatchedFor(chosenKey);
    if (!fresh.length) return;
    setMatching(true);
    const roomName = (id: string) => property.rooms.find((r) => r.id === id)?.name;
    callAI<{ matches: Match[] }>('match_products', {
      items: fresh.map((l) => ({ id: l.key, name: l.name, category: l.category, notes: l.description, quantity: l.quantity, room: roomName(l.roomId) })),
    }).then(({ matches }) => {
      setLines((current) => current.map((l) => {
        const m = matches.find((x) => x.item_id === l.key);
        if (!m) return l;
        const p = m.product_id ? productMap.get(m.product_id) : undefined;
        return p
          ? { ...l, productId: p.id, unitPrice: p.list_price ?? p.msrp ?? 0, unitCost: p.base_cost ?? 0, matchNote: `${m.confidence} match: ${m.reason}` }
          : { ...l, unitPrice: m.estimated_unit_price, unitCost: m.estimated_unit_cost, matchNote: `No product found. AI price estimate: ${m.reason}` };
      }));
    }).catch((e) => setError(`Product matching didn't work (${e.message}). Pick products and prices yourself.`))
      .finally(() => setMatching(false));
  }, [step]); // eslint-disable-line react-hooks/exhaustive-deps

  const setLine = (key: string, fields: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...fields } : l)));
  const pickProduct = (key: string, productId: string) => {
    const p = productMap.get(productId);
    setLine(key, p ? { productId, unitPrice: p.list_price ?? p.msrp ?? 0, unitCost: p.base_cost ?? 0, matchNote: 'Chosen by you' } : { productId: '' });
  };

  const taxRate = client.taxExempt ? 0 : client.taxRate;
  const t = totals(lines, taxRate);

  const canNext = [
    chosen.size > 0,
    client.name.trim().length > 0,
    title.trim().length > 0,
    true,
    !matching && lines.length > 0,
    true,
  ][step];

  const create = async () => {
    setCreating(true);
    setError('');
    try {
      const id = await createQuote({
        propertyId: property.id,
        title: title.trim(),
        client: { ...client, existingId: client.existingId || undefined },
        crm: { stage, leadSource, probability: probability ? parseFloat(probability) : null, notes: salesNotes },
        template: templates?.find((x) => x.id === templateId) ?? null,
        groupByRoom,
        rooms: property.rooms,
        lines,
        products: productMap,
        notes,
      });
      setCreatedId(id);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setCreating(false);
    }
  };

  const toggleItem = (id: string) => setChosen((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const setMany = (ids: string[], on: boolean) => setChosen((s) => { const n = new Set(s); ids.forEach((id) => (on ? n.add(id) : n.delete(id))); return n; });
  const allIds = property.rooms.flatMap((r) => r.items.map((i) => i.id));

  if (createdId) {
    return (
      <Modal onClose={onClose}>
        <div className="center-block">
          <h2>Quote ready for review</h2>
          <p>A draft quote "{title}" for {client.name} with {lines.length} line(s) totaling {money(t.total)} is in QuoteMaster. Nothing was sent to the customer.</p>
          <div className="actions center">
            <a className="button primary" href={`${QUOTEMASTER_URL}/QuoteEditor?id=${createdId}`} target="_blank" rel="noreferrer">Open in QuoteMaster</a>
            <button onClick={onClose}>Done</button>
          </div>
        </div>
      </Modal>
    );
  }

  return (
    <Modal onClose={onClose}>
      <div className="wizard-head">
        <h2>Send to QuoteMaster</h2>
        <ol className="steps">
          {STEPS.map((s, i) => <li key={s} className={i === step ? 'on' : i < step ? 'done' : ''}>{s}</li>)}
        </ol>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="wizard-body">
        {step === 0 && (
          <>
            <p className="muted">Choose what goes on the quote. Customer requests are selected to start with.</p>
            <div className="actions">
              <button onClick={() => setMany(property.rooms.flatMap((r) => r.items.filter((i) => i.isRequested).map((i) => i.id)), true)}>Add all requests</button>
              <button onClick={() => setMany(property.rooms.flatMap((r) => r.items.filter((i) => !i.isRequested && i.condition !== 'good').map((i) => i.id)), true)}>Add items needing work</button>
              <button className="link" onClick={() => setMany(allIds, false)}>Clear</button>
            </div>
            {property.rooms.map((room) => room.items.length > 0 && (
              <div key={room.id} className="wizard-room">
                <div className="sub-head">
                  <strong>{room.name}</strong>
                  <button className="link" onClick={() => setMany(room.items.map((i) => i.id), !room.items.every((i) => chosen.has(i.id)))}>
                    {room.items.every((i) => chosen.has(i.id)) ? 'None' : 'All'}
                  </button>
                </div>
                {room.items.map((i) => (
                  <label key={i.id} className="check row-check">
                    <input type="checkbox" checked={chosen.has(i.id)} onChange={() => toggleItem(i.id)} />
                    <span>{i.name}{i.quantity > 1 ? ` ×${i.quantity}` : ''}</span>
                    <span className="muted small">{i.isRequested ? 'requested' : conditionLabel(i.condition)} · {i.category}</span>
                  </label>
                ))}
              </div>
            ))}
            <label className="check"><input type="checkbox" checked={combine} onChange={(e) => setCombine(e.target.checked)} /> Combine identical items in a room into one line (3 outlets become qty 3)</label>
            <label className="check"><input type="checkbox" checked={groupByRoom} onChange={(e) => setGroupByRoom(e.target.checked)} /> Group lines by room with a heading for each</label>
          </>
        )}

        {step === 1 && (
          <>
            <label>Find a client in QuoteMaster<input value={clientQuery} onChange={(e) => setClientQuery(e.target.value)} placeholder="Name or company" /></label>
            <div className="client-list">
              {clients.map((c) => (
                <button key={c.id} className={`list-row ${client.existingId === c.id ? 'on' : ''}`} onClick={() => setClient({
                  existingId: c.id, saveNew: false, name: c.name, email: c.email ?? '', company: c.company ?? '', phone: c.phone ?? '',
                  address: c.address ?? '', city: c.city ?? '', state: c.state ?? '', zip: c.zip ?? '',
                  taxRate: c.tax_rate ?? 0, taxExempt: !!c.is_tax_exempt,
                })}>
                  <span>{c.name}</span><span className="muted small">{[c.company, c.email].filter(Boolean).join(' · ')}</span>
                </button>
              ))}
              {!clients.length && <div className="muted small">No matching clients. Fill in a new one below.</div>}
            </div>
            {client.existingId && <div className="ok small">Using existing client {client.name}. <button className="link" onClick={() => setClient({ ...client, existingId: '', saveNew: true })}>Make a new one instead</button></div>}
            <div className="row wrap">
              <label>Name<input value={client.name} onChange={(e) => setClient({ ...client, name: e.target.value })} /></label>
              <label>Company<input value={client.company} onChange={(e) => setClient({ ...client, company: e.target.value })} /></label>
            </div>
            <div className="row wrap">
              <label>Email<input value={client.email} onChange={(e) => setClient({ ...client, email: e.target.value })} /></label>
              <label>Phone<input value={client.phone} onChange={(e) => setClient({ ...client, phone: e.target.value })} /></label>
            </div>
            <label>Address<input value={client.address} onChange={(e) => setClient({ ...client, address: e.target.value })} /></label>
            <div className="row wrap">
              <label>City<input value={client.city} onChange={(e) => setClient({ ...client, city: e.target.value })} /></label>
              <label className="narrow">State<input value={client.state} onChange={(e) => setClient({ ...client, state: e.target.value })} /></label>
              <label className="narrow">ZIP<input value={client.zip} onChange={(e) => setClient({ ...client, zip: e.target.value })} /></label>
              <label className="narrow">Tax %<input type="number" step="0.01" value={client.taxRate} onChange={(e) => setClient({ ...client, taxRate: parseFloat(e.target.value) || 0 })} /></label>
            </div>
            <label className="check"><input type="checkbox" checked={client.taxExempt} onChange={(e) => setClient({ ...client, taxExempt: e.target.checked })} /> Tax exempt</label>
            {!client.existingId && <label className="check"><input type="checkbox" checked={client.saveNew} onChange={(e) => setClient({ ...client, saveNew: e.target.checked })} /> Save to QuoteMaster's client list</label>}
          </>
        )}

        {step === 2 && (
          <>
            <label>Deal title<input value={title} onChange={(e) => setTitle(e.target.value)} /></label>
            <div className="muted small">Stage</div>
            <div className="segmented">
              {CRM_STAGES.map((s) => <button key={s.value} className={stage === s.value ? 'on' : ''} onClick={() => setStage(s.value)}>{s.label}</button>)}
            </div>
            <div className="row wrap">
              <label>Lead source
                <select value={leadSource} onChange={(e) => setLeadSource(e.target.value)}>
                  <option value="">Not set</option>
                  {LEAD_SOURCES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
                </select>
              </label>
              <label className="narrow">Win probability %<input type="number" min={0} max={100} value={probability} onChange={(e) => setProbability(e.target.value)} /></label>
            </div>
            <label>Sales notes (internal)<textarea rows={3} value={salesNotes} onChange={(e) => setSalesNotes(e.target.value)} /></label>
          </>
        )}

        {step === 3 && (
          <>
            <p className="muted">Pick how the quote looks. You can change it later in QuoteMaster.</p>
            <div className="template-grid">
              <button className={`card template ${templateId === '' ? 'on' : ''}`} onClick={() => setTemplateId('')}>
                <strong>Classic</strong><span className="muted small">QuoteMaster's standard layout</span>
              </button>
              {(templates ?? []).map((tpl) => (
                <button key={tpl.id} className={`card template ${templateId === tpl.id ? 'on' : ''}`} onClick={() => setTemplateId(tpl.id)}>
                  <span className="swatch" style={{ background: tpl.primary_color || '#2563eb' }} />
                  <strong>{tpl.name}</strong>
                  {tpl.description && <span className="muted small">{tpl.description}</span>}
                  {tpl.is_default && <span className="badge">Default</span>}
                </button>
              ))}
            </div>
            {templates === null && <p className="muted">Loading templates…</p>}
          </>
        )}

        {step === 4 && (
          <>
            <p className="muted">{matching ? 'The AI is matching items to your QuoteMaster products…' : 'Check each line. Matched products use your list price; unmatched lines use an AI estimate you should check.'}</p>
            <table className="table">
              <thead><tr><th>Item</th><th>Product</th><th>Qty</th><th>Unit price</th><th>Unit cost</th><th>Line</th></tr></thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.key}>
                    <td>
                      <input className="cell" value={l.name} onChange={(e) => setLine(l.key, { name: e.target.value })} />
                      <div className="muted small">{property.rooms.find((r) => r.id === l.roomId)?.name}{l.matchNote ? ` · ${l.matchNote}` : ''}</div>
                    </td>
                    <td>
                      <select className="cell" value={l.productId} onChange={(e) => pickProduct(l.key, e.target.value)}>
                        <option value="">Custom line (no product)</option>
                        {products.map((p) => <option key={p.id} value={p.id}>{p.name}{p.sku ? ` (${p.sku})` : ''}</option>)}
                      </select>
                    </td>
                    <td><input className="cell qty" type="number" min={1} value={l.quantity} onChange={(e) => setLine(l.key, { quantity: Math.max(1, parseInt(e.target.value) || 1) })} /></td>
                    <td><input className="cell money" type="number" step="0.01" value={l.unitPrice} onChange={(e) => setLine(l.key, { unitPrice: parseFloat(e.target.value) || 0 })} /></td>
                    <td><input className="cell money" type="number" step="0.01" value={l.unitCost} onChange={(e) => setLine(l.key, { unitCost: parseFloat(e.target.value) || 0 })} /></td>
                    <td>{money(l.unitPrice * l.quantity)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="totals">Subtotal {money(t.subtotal)}</div>
          </>
        )}

        {step === 5 && (
          <>
            <div className="facts">
              <div><span className="muted small">Client</span>{client.name}{client.existingId ? '' : client.saveNew ? ' (new, saved)' : ' (new)'}</div>
              <div><span className="muted small">Deal</span>{title} · {CRM_STAGES.find((s) => s.value === stage)?.label}</div>
              <div><span className="muted small">Template</span>{templates?.find((x) => x.id === templateId)?.name ?? 'Classic'}</div>
            </div>
            <div className="facts">
              <div><span className="muted small">Lines</span>{lines.length} in {rooms.length} room(s)</div>
              <div><span className="muted small">Subtotal</span>{money(t.subtotal)}</div>
              <div><span className="muted small">Tax ({taxRate}%)</span>{money(t.tax)}</div>
              <div><span className="muted small">Total</span><strong>{money(t.total)}</strong></div>
              <div><span className="muted small">Margin</span>{t.margin}%</div>
            </div>
            {lines.some((l) => !l.unitPrice) && <div className="banner warn">{lines.filter((l) => !l.unitPrice).length} line(s) have no price yet.</div>}
            <label>Notes on the quote (the customer sees these)<textarea rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} /></label>
            <p className="muted small">This creates a draft quote. Nothing is sent to the customer.</p>
          </>
        )}
      </div>
      <div className="wizard-foot">
        <button onClick={() => (step === 0 ? onClose() : setStep(step - 1))}>{step === 0 ? 'Cancel' : 'Back'}</button>
        <span className="spacer" />
        {step < STEPS.length - 1
          ? <button className="primary" disabled={!canNext} onClick={() => setStep(step + 1)}>Next</button>
          : <button className="primary" disabled={creating} onClick={create}>{creating ? 'Creating…' : 'Create Draft Quote'}</button>}
      </div>
    </Modal>
  );
}

function Modal({ children, onClose }: { children: React.ReactNode; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  return (
    <div className="modal-back" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="modal card">{children}</div>
    </div>
  );
}
