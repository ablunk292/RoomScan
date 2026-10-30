import { useEffect, useMemo, useRef, useState } from 'react';
import {
  bounds, centroid, contains, dist, formatArea, formatLength, area, itemAndEverythingOn, newItem, newRoom,
  parseLength, type Point, type Property, type Room,
} from '../lib/model';

export type Selection =
  | { kind: 'room'; roomId: string }
  | { kind: 'item'; roomId: string; itemId: string }
  | null;

type Tool = 'select' | 'item' | 'request' | 'room';

type Drag =
  | { kind: 'pan'; start: Point; view: View }
  | { kind: 'room'; roomId: string; start: Point; original: Room }
  | { kind: 'corner'; roomId: string; index: number; start: Point; original: Room }
  | { kind: 'item'; roomId: string; itemId: string; start: Point; original: Room };

type View = { x: number; y: number; scale: number }; // scale = pixels per meter

const CATEGORY_COLORS: Record<string, string> = {
  Appliance: '#0ea5e9', Electrical: '#eab308', Plumbing: '#06b6d4', HVAC: '#8b5cf6', Lighting: '#f59e0b',
  Furniture: '#a16207', Fixture: '#64748b', 'Network / AV': '#6366f1', Security: '#ef4444', Flooring: '#78716c',
  'Window / Door': '#14b8a6', Other: '#94a3b8',
};
export const categoryColor = (c: string) => CATEGORY_COLORS[c] ?? '#94a3b8';

type Props = {
  property: Property;
  feet: boolean;
  selection: Selection;
  onSelect: (s: Selection) => void;
  update: (change: (draft: Property) => void, options?: { skipUndo?: boolean }) => void;
  checkpoint: () => void;
};

export default function FloorPlanEditor({ property, feet, selection, onSelect, update, checkpoint }: Props) {
  const svgRef = useRef<SVGSVGElement>(null);
  const [size, setSize] = useState({ w: 800, h: 600 });
  const [view, setView] = useState<View | null>(null);
  const [tool, setTool] = useState<Tool>('select');
  const [snap, setSnap] = useState(true);
  const [drag, setDrag] = useState<Drag | null>(null);
  const [hoverCorner, setHoverCorner] = useState<{ roomId: string; index: number } | null>(null);
  const [selectedCorner, setSelectedCorner] = useState<{ roomId: string; index: number } | null>(null);
  const moved = useRef(false);

  const grid = feet ? 0.3048 : 0.5;
  const snapTo = (v: number, on: boolean) => (on && snap ? Math.round(v / (grid / 4)) * (grid / 4) : v);

  // Keep the drawing sized to its box.
  useEffect(() => {
    const el = svgRef.current?.parentElement;
    if (!el) return;
    const observer = new ResizeObserver(([entry]) => {
      setSize({ w: entry.contentRect.width, h: entry.contentRect.height });
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const fit = () => {
    const pts = property.rooms.flatMap((r) => r.outline);
    const b = bounds(pts.length ? pts : [{ x: 0, y: 0 }, { x: 8, y: 6 }]);
    const pad = 1.2;
    const scale = Math.min(size.w / (b.maxX - b.minX + pad * 2), size.h / (b.maxY - b.minY + pad * 2));
    setView({
      scale,
      x: b.minX - pad - (size.w / scale - (b.maxX - b.minX + pad * 2)) / 2,
      y: b.minY - pad - (size.h / scale - (b.maxY - b.minY + pad * 2)) / 2,
    });
  };
  useEffect(() => { if (!view && size.w > 0) fit(); }, [size, property]); // eslint-disable-line react-hooks/exhaustive-deps

  const v = view ?? { x: 0, y: 0, scale: 60 };
  const toScreen = (p: Point) => ({ x: (p.x - v.x) * v.scale, y: (p.y - v.y) * v.scale });
  const toWorld = (e: { clientX: number; clientY: number }): Point => {
    const rect = svgRef.current!.getBoundingClientRect();
    return { x: (e.clientX - rect.left) / v.scale + v.x, y: (e.clientY - rect.top) / v.scale + v.y };
  };

  const onWheel = (e: React.WheelEvent) => {
    const p = toWorld(e);
    const factor = Math.exp(-e.deltaY * 0.0015);
    const scale = Math.min(400, Math.max(8, v.scale * factor));
    setView({ scale, x: p.x - (p.x - v.x) * (v.scale / scale), y: p.y - (p.y - v.y) * (v.scale / scale) });
  };

  // ── Pointer handling ──────────────────────────────────────────────────────
  const roomAt = (p: Point) => [...property.rooms].reverse().find((r) => contains(r.outline, p));

  const startDrag = (e: React.PointerEvent, d: Drag) => {
    e.stopPropagation();
    (e.target as Element).setPointerCapture?.(e.pointerId);
    moved.current = false;
    setDrag(d);
  };

  const onBackgroundDown = (e: React.PointerEvent) => {
    const p = toWorld(e);
    if (tool === 'room') {
      const name = prompt('Room name', `Room ${property.rooms.length + 1}`);
      if (name?.trim()) {
        const room = newRoom(name.trim(), { x: snapTo(p.x, true), y: snapTo(p.y, true) });
        update((d) => { d.rooms.push(room); });
        onSelect({ kind: 'room', roomId: room.id });
      }
      setTool('select');
      return;
    }
    if (tool === 'item' || tool === 'request') {
      const room = roomAt(p);
      if (!room) { alert('Click inside a room to place the item.'); return; }
      const item = newItem({ position: p, isRequested: tool === 'request', name: tool === 'request' ? 'Requested item' : 'New item' });
      update((d) => { d.rooms.find((r) => r.id === room.id)!.items.push(item); });
      onSelect({ kind: 'item', roomId: room.id, itemId: item.id });
      setTool('select');
      return;
    }
    const room = roomAt(p);
    if (room) {
      onSelect({ kind: 'room', roomId: room.id });
      setSelectedCorner(null);
      startDrag(e, { kind: 'room', roomId: room.id, start: p, original: structuredClone(room) });
    } else {
      onSelect(null);
      setSelectedCorner(null);
      startDrag(e, { kind: 'pan', start: { x: e.clientX, y: e.clientY }, view: v });
    }
  };

  const onMove = (e: React.PointerEvent) => {
    if (!drag) return;
    // The first movement of a drag is one undo step; a plain click is none.
    if (!moved.current && drag.kind !== 'pan') checkpoint();
    moved.current = true;
    if (drag.kind === 'pan') {
      setView({
        scale: drag.view.scale,
        x: drag.view.x - (e.clientX - drag.start.x) / drag.view.scale,
        y: drag.view.y - (e.clientY - drag.start.y) / drag.view.scale,
      });
      return;
    }
    const p = toWorld(e);
    const free = e.altKey;
    const dx = p.x - drag.start.x;
    const dy = p.y - drag.start.y;
    const o = drag.original;
    update((d) => {
      const room = d.rooms.find((r) => r.id === drag.roomId);
      if (!room) return;
      if (drag.kind === 'room') {
        // Snap the first corner, and move everything in the room by the same amount.
        const sx = snapTo(o.outline[0].x + dx, !free) - o.outline[0].x;
        const sy = snapTo(o.outline[0].y + dy, !free) - o.outline[0].y;
        const mv = (q: Point) => ({ x: q.x + sx, y: q.y + sy });
        room.outline = o.outline.map(mv);
        room.openings = o.openings.map((op) => ({ ...op, start: mv(op.start), end: mv(op.end) }));
        room.items = o.items.map((it) => (it.position ? { ...it, position: mv(it.position) } : it));
      } else if (drag.kind === 'corner') {
        const c = o.outline[drag.index];
        room.outline[drag.index] = { x: snapTo(c.x + dx, !free), y: snapTo(c.y + dy, !free) };
      } else if (drag.kind === 'item') {
        const moving = itemAndEverythingOn(o, drag.itemId);
        room.items = o.items.map((it) => (moving.has(it.id) && it.position
          ? { ...it, position: { x: it.position.x + dx, y: it.position.y + dy } } : it));
      }
    }, { skipUndo: true });
  };

  const onUp = () => {
    if (drag && drag.kind === 'item') {
      // An item dropped into another room moves to that room.
      const room = property.rooms.find((r) => r.id === drag.roomId);
      const item = room?.items.find((i) => i.id === drag.itemId);
      if (room && item?.position && !contains(room.outline, item.position)) {
        const target = roomAt(item.position);
        if (target && target.id !== room.id) {
          const ids = itemAndEverythingOn(room, item.id);
          update((d) => {
            const from = d.rooms.find((r) => r.id === room.id)!;
            const to = d.rooms.find((r) => r.id === target.id)!;
            const movingItems = from.items.filter((i) => ids.has(i.id));
            from.items = from.items.filter((i) => !ids.has(i.id));
            to.items.push(...movingItems);
          }, { skipUndo: true });
          onSelect({ kind: 'item', roomId: target.id, itemId: item.id });
        }
      }
    }
    setDrag(null);
  };

  // Delete a selected corner with the Delete key.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement).closest('input, textarea, select')) return;
      if ((e.key === 'Delete' || e.key === 'Backspace') && selectedCorner) {
        const room = property.rooms.find((r) => r.id === selectedCorner.roomId);
        if (!room || room.outline.length <= 3) return;
        e.preventDefault();
        update((d) => { d.rooms.find((r) => r.id === selectedCorner.roomId)!.outline.splice(selectedCorner.index, 1); });
        setSelectedCorner(null);
      }
      if (e.key === 'Escape') { setTool('select'); setSelectedCorner(null); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [selectedCorner, property, update]);

  const addCornerOnEdge = (room: Room, index: number, at: Point) => {
    update((d) => { d.rooms.find((r) => r.id === room.id)!.outline.splice(index + 1, 0, at); });
  };

  const setWallLength = (room: Room, index: number) => {
    const a = room.outline[index];
    const b = room.outline[(index + 1) % room.outline.length];
    const current = dist(a, b);
    const text = prompt(`New length for this wall (now ${formatLength(current, feet)}). The corner after it moves; the rest stays put.`, formatLength(current, feet).replace(/[′″]/g, (m) => (m === '′' ? "'" : '"')));
    if (!text) return;
    const length = parseLength(text, feet);
    if (!length || length <= 0) { alert('That length was not understood. Try 12\' 6" or 3.8 m.'); return; }
    const ux = (b.x - a.x) / current;
    const uy = (b.y - a.y) / current;
    update((d) => {
      const r = d.rooms.find((x) => x.id === room.id)!;
      r.outline[(index + 1) % r.outline.length] = { x: a.x + ux * length, y: a.y + uy * length };
    });
  };

  // ── Drawing ───────────────────────────────────────────────────────────────
  const gridLines = useMemo(() => {
    const lines: JSX.Element[] = [];
    if (!view) return lines;
    const x0 = Math.floor(v.x / grid) * grid;
    const y0 = Math.floor(v.y / grid) * grid;
    const x1 = v.x + size.w / v.scale;
    const y1 = v.y + size.h / v.scale;
    if ((x1 - x0) / grid > 400) return lines;
    for (let x = x0; x <= x1; x += grid) {
      const sx = (x - v.x) * v.scale;
      lines.push(<line key={`x${x.toFixed(3)}`} x1={sx} x2={sx} y1={0} y2={size.h} className="grid-line" />);
    }
    for (let y = y0; y <= y1; y += grid) {
      const sy = (y - v.y) * v.scale;
      lines.push(<line key={`y${y.toFixed(3)}`} x1={0} x2={size.w} y1={sy} y2={sy} className="grid-line" />);
    }
    return lines;
  }, [view, size, grid]); // eslint-disable-line react-hooks/exhaustive-deps

  const selectedRoomId = selection?.roomId;
  const selectedItemId = selection?.kind === 'item' ? selection.itemId : null;

  return (
    <div className="plan">
      <div className="plan-tools">
        <div className="segmented">
          <button className={tool === 'select' ? 'on' : ''} onClick={() => setTool('select')} title="Select and drag (Esc)">Select</button>
          <button className={tool === 'item' ? 'on' : ''} onClick={() => setTool('item')} title="Click inside a room to add an existing item">+ Item</button>
          <button className={tool === 'request' ? 'on' : ''} onClick={() => setTool('request')} title="Click inside a room to add something the customer asked for">+ Request</button>
          <button className={tool === 'room' ? 'on' : ''} onClick={() => setTool('room')} title="Click to place a new room">+ Room</button>
        </div>
        <label className="check"><input type="checkbox" checked={snap} onChange={(e) => setSnap(e.target.checked)} /> Snap</label>
        <span className="spacer" />
        <button className="ghost" onClick={() => setView({ ...v, scale: Math.min(400, v.scale * 1.25) })}>+</button>
        <button className="ghost" onClick={() => setView({ ...v, scale: Math.max(8, v.scale / 1.25) })}>−</button>
        <button className="ghost" onClick={fit}>Fit</button>
      </div>
      <div className="plan-hint muted small">
        {tool === 'select' && 'Drag a room to move it. Select a room to drag its corners, double-click a wall to add a corner, or click a length to type it. Drag items to move them. Hold Alt to turn off snapping.'}
        {tool === 'item' && 'Click inside a room where the item is.'}
        {tool === 'request' && 'Click inside a room where the customer wants the new item.'}
        {tool === 'room' && 'Click where the new room\'s top-left corner should go. It starts as a 12 ft square you can reshape.'}
      </div>
      <div className="plan-canvas">
        <svg
          ref={svgRef}
          width={size.w}
          height={size.h}
          onPointerDown={onBackgroundDown}
          onPointerMove={onMove}
          onPointerUp={onUp}
          onWheel={onWheel}
          className={`tool-${tool}`}
        >
          <g>{gridLines}</g>
          {property.rooms.map((room) => {
            const pts = room.outline.map(toScreen);
            const selected = room.id === selectedRoomId;
            const c = toScreen(centroid(room.outline));
            return (
              <g key={room.id} className={`room ${selected ? 'selected' : ''}`}>
                <polygon points={pts.map((p) => `${p.x},${p.y}`).join(' ')} />
                {room.openings.map((op) => {
                  const a = toScreen(op.start);
                  const b = toScreen(op.end);
                  return <line key={op.id} x1={a.x} y1={a.y} x2={b.x} y2={b.y} className={`op op-${op.kind}`} />;
                })}
                <text x={c.x} y={c.y - 6} className="room-name">{room.name}</text>
                <text x={c.x} y={c.y + 10} className="room-area">{formatArea(area(room.outline), feet)}</text>
                {selected && pts.map((p, i) => {
                  const q = pts[(i + 1) % pts.length];
                  const a = room.outline[i];
                  const b = room.outline[(i + 1) % room.outline.length];
                  const mid = { x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 };
                  return (
                    <g key={`e${i}`}>
                      <line
                        x1={p.x} y1={p.y} x2={q.x} y2={q.y} className="edge-hit"
                        onDoubleClick={(e) => { e.stopPropagation(); addCornerOnEdge(room, i, toWorld(e)); }}
                      />
                      <g className="wall-label" onPointerDown={(e) => { e.stopPropagation(); setWallLength(room, i); }}>
                        <rect x={mid.x - 28} y={mid.y - 10} width={56} height={20} rx={4} />
                        <text x={mid.x} y={mid.y + 4}>{formatLength(dist(a, b), feet)}</text>
                      </g>
                    </g>
                  );
                })}
                {selected && pts.map((p, i) => (
                  <circle
                    key={`c${i}`}
                    cx={p.x} cy={p.y} r={hoverCorner?.roomId === room.id && hoverCorner.index === i ? 8 : 6}
                    className={`corner ${selectedCorner?.roomId === room.id && selectedCorner.index === i ? 'on' : ''}`}
                    onPointerEnter={() => setHoverCorner({ roomId: room.id, index: i })}
                    onPointerLeave={() => setHoverCorner(null)}
                    onPointerDown={(e) => {
                      setSelectedCorner({ roomId: room.id, index: i });
                      startDrag(e, { kind: 'corner', roomId: room.id, index: i, start: toWorld(e), original: structuredClone(room) });
                    }}
                  />
                ))}
              </g>
            );
          })}
          {property.rooms.map((room) => room.items.map((item) => {
            if (!item.position) return null;
            const p = toScreen(item.position);
            const parent = item.parentID ? room.items.find((i) => i.id === item.parentID) : undefined;
            const pp = parent?.position ? toScreen(parent.position) : null;
            const selected = item.id === selectedItemId;
            return (
              <g key={item.id} className={`pin ${selected ? 'selected' : ''} ${item.isRequested ? 'requested' : ''}`}>
                {pp && <line x1={pp.x} y1={pp.y} x2={p.x} y2={p.y} className="stack-line" />}
                <circle
                  cx={p.x} cy={p.y} r={selected ? 9 : 7}
                  fill={categoryColor(item.category)}
                  onPointerDown={(e) => {
                    if (tool !== 'select') return;
                    onSelect({ kind: 'item', roomId: room.id, itemId: item.id });
                    startDrag(e, { kind: 'item', roomId: room.id, itemId: item.id, start: toWorld(e), original: structuredClone(room) });
                  }}
                >
                  <title>{`${item.name}${item.quantity > 1 ? ` ×${item.quantity}` : ''} (${item.category})${item.isRequested ? ' – requested' : ''}`}</title>
                </circle>
                {(selected || v.scale > 90) && <text x={p.x + 11} y={p.y + 4} className="pin-label">{item.name}</text>}
              </g>
            );
          }))}
        </svg>
        {property.rooms.length === 0 && (
          <div className="plan-empty card">
            <strong>No rooms yet.</strong> Map rooms with the iPhone app, or choose <em>+ Room</em> and click to draw one here.
          </div>
        )}
      </div>
      <div className="legend small">
        <span><i className="dot" style={{ background: '#94a3b8' }} /> Existing item</span>
        <span><i className="dot ring" /> Customer request</span>
        <span><i className="bar door" /> Door</span>
        <span><i className="bar window" /> Window</span>
        <span><i className="bar opening" /> Opening</span>
      </div>
    </div>
  );
}
