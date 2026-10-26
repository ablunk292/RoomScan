import { useRef, useState } from 'react';
import { callAI } from '../lib/supabase';
import { newItem, type Property } from '../lib/model';

type Proposed = { room_id: string; name: string; category: string; quantity: number; is_requested: boolean; notes: string };
type Message = { role: 'user' | 'assistant'; text: string; proposed?: Proposed[]; applied?: boolean };

const SUGGESTIONS = [
  'Summarize what the customer asked for, room by room.',
  'Which existing items need repair or replacement?',
  'Write a short scope of work for this job.',
  'Add a smoke detector to every bedroom that does not have one.',
];

/** Strips what the AI doesn't need, to keep requests small. */
function forAI(p: Property) {
  return {
    name: p.name, address: p.address, notes: p.notes, customer: p.customerName,
    rooms: p.rooms.map((r) => ({
      id: r.id, name: r.name, outline: r.outline.map((q) => [+q.x.toFixed(2), +q.y.toFixed(2)]),
      ceilingHeight: r.ceilingHeight, notes: r.notes,
      openings: r.openings.map((o) => o.kind),
      measurements: (r.measurements ?? []).map((m) => ({ name: m.name, length: +m.length.toFixed(3) })),
      items: r.items.map((i) => ({
        id: i.id, name: i.name, category: i.category, quantity: i.quantity, isRequested: i.isRequested,
        condition: i.condition, notes: i.notes, on: i.parentID,
      })),
    })),
  };
}

export default function AIHelper({ property, update, onClose }: {
  property: Property;
  update: (change: (draft: Property) => void) => void;
  onClose: () => void;
}) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const end = useRef<HTMLDivElement>(null);

  const send = async (text: string) => {
    if (!text.trim() || busy) return;
    const history = messages.map((m) => ({ role: m.role, text: m.text }));
    setMessages((m) => [...m, { role: 'user', text }]);
    setInput('');
    setBusy(true);
    try {
      const res = await callAI<{ reply: string; add_items: Proposed[] }>('assist', { message: text, history, property: forAI(property) });
      const proposed = (res.add_items || []).filter((p) => property.rooms.some((r) => r.id === p.room_id));
      setMessages((m) => [...m, { role: 'assistant', text: res.reply, proposed: proposed.length ? proposed : undefined }]);
    } catch (e) {
      setMessages((m) => [...m, { role: 'assistant', text: `Sorry, that didn't work: ${(e as Error).message}` }]);
    } finally {
      setBusy(false);
      setTimeout(() => end.current?.scrollIntoView({ behavior: 'smooth' }), 50);
    }
  };

  const apply = (index: number) => {
    const msg = messages[index];
    if (!msg.proposed) return;
    update((d) => {
      for (const p of msg.proposed!) {
        const room = d.rooms.find((r) => r.id === p.room_id);
        room?.items.push(newItem({
          name: p.name, category: p.category, quantity: Math.max(1, p.quantity || 1),
          isRequested: p.is_requested, notes: p.notes,
        }));
      }
    });
    setMessages((m) => m.map((x, i) => (i === index ? { ...x, applied: true } : x)));
  };

  const roomName = (id: string) => property.rooms.find((r) => r.id === id)?.name ?? 'Room';

  return (
    <aside className="ai">
      <div className="panel-head">
        <strong>AI helper</strong>
        <span className="spacer" />
        <button className="ghost" onClick={onClose}>✕</button>
      </div>
      <div className="ai-messages">
        {!messages.length && (
          <div className="muted small">
            Ask about this walkthrough, or ask it to add items. It never changes anything until you click Add.
            <div className="suggestions">
              {SUGGESTIONS.map((s) => <button key={s} className="chip" onClick={() => send(s)}>{s}</button>)}
            </div>
          </div>
        )}
        {messages.map((m, i) => (
          <div key={i} className={`msg ${m.role}`}>
            <div className="msg-text">{m.text}</div>
            {m.proposed && (
              <div className="proposed">
                {m.proposed.map((p, j) => (
                  <div key={j} className="small">• {p.quantity > 1 ? `${p.quantity} × ` : ''}{p.name} in {roomName(p.room_id)}{p.is_requested ? ' (requested)' : ''}</div>
                ))}
                <button className="primary small" disabled={m.applied} onClick={() => apply(i)}>
                  {m.applied ? 'Added' : `Add ${m.proposed.length} item(s)`}
                </button>
              </div>
            )}
          </div>
        ))}
        {busy && <div className="msg assistant muted">Thinking…</div>}
        <div ref={end} />
      </div>
      <form className="ai-input" onSubmit={(e) => { e.preventDefault(); send(input); }}>
        <textarea
          rows={2} value={input} placeholder="Ask about this walkthrough…"
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(input); } }}
        />
        <button className="primary" disabled={busy || !input.trim()}>Send</button>
      </form>
    </aside>
  );
}
