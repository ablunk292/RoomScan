import { useCallback, useEffect, useRef, useState } from 'react';
import { getProperty, saveProperty, StaleError } from './store';
import type { Property } from './model';

export type SaveState = 'saved' | 'unsaved' | 'saving' | 'error' | 'stale';

/** Loads a walkthrough, applies edits with undo and redo, and saves a moment after each change. */
export function useWalkthrough(id: string) {
  const [property, setProperty] = useState<Property | null>(null);
  const [loadError, setLoadError] = useState('');
  const [saveState, setSaveState] = useState<SaveState>('saved');
  const [saveError, setSaveError] = useState('');
  const version = useRef(0);
  const undoStack = useRef<Property[]>([]);
  const redoStack = useRef<Property[]>([]);
  const timer = useRef<number>();
  const latest = useRef<Property | null>(null);
  const [, bump] = useState(0);

  const load = useCallback(async () => {
    try {
      const row = await getProperty(id);
      if (!row) { setLoadError('This walkthrough was not found, or it belongs to another company.'); return; }
      version.current = row.version;
      latest.current = row.data;
      setProperty(row.data);
      setSaveState('saved');
      undoStack.current = [];
      redoStack.current = [];
    } catch (e) {
      setLoadError((e as Error).message);
    }
  }, [id]);

  useEffect(() => { load(); }, [load]);

  const flush = useCallback(async () => {
    window.clearTimeout(timer.current);
    const p = latest.current;
    if (!p) return;
    setSaveState('saving');
    try {
      version.current = await saveProperty(p, version.current);
      setSaveState(latest.current === p ? 'saved' : 'unsaved');
      setSaveError('');
    } catch (e) {
      setSaveState(e instanceof StaleError ? 'stale' : 'error');
      setSaveError((e as Error).message);
    }
  }, []);

  const schedule = useCallback(() => {
    setSaveState('unsaved');
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(flush, 1200);
  }, [flush]);

  /** Applies a change to a copy of the walkthrough. A drag passes skipUndo after one `checkpoint`. */
  const update = useCallback((change: (draft: Property) => void, options: { skipUndo?: boolean } = {}) => {
    const current = latest.current;
    if (!current) return;
    const draft = structuredClone(current);
    change(draft);
    if (!options.skipUndo) {
      undoStack.current.push(current);
      if (undoStack.current.length > 100) undoStack.current.shift();
      redoStack.current = [];
    }
    latest.current = draft;
    setProperty(draft);
    schedule();
  }, [schedule]);

  /** Marks the current state as an undo point before a drag starts. */
  const checkpoint = useCallback(() => {
    if (!latest.current) return;
    undoStack.current.push(latest.current);
    redoStack.current = [];
    bump((n) => n + 1);
  }, []);

  const undo = useCallback(() => {
    const prev = undoStack.current.pop();
    if (!prev || !latest.current) return;
    redoStack.current.push(latest.current);
    latest.current = prev;
    setProperty(prev);
    schedule();
  }, [schedule]);

  const redo = useCallback(() => {
    const next = redoStack.current.pop();
    if (!next || !latest.current) return;
    undoStack.current.push(latest.current);
    latest.current = next;
    setProperty(next);
    schedule();
  }, [schedule]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;
      if (target.closest('input, textarea, select')) return;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z') {
        e.preventDefault();
        if (e.shiftKey) redo(); else undo();
      }
    };
    const beforeUnload = (e: BeforeUnloadEvent) => {
      if (latest.current && saveStateRef.current !== 'saved') e.preventDefault();
    };
    window.addEventListener('keydown', onKey);
    window.addEventListener('beforeunload', beforeUnload);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('beforeunload', beforeUnload);
    };
  }, [undo, redo]);

  const saveStateRef = useRef(saveState);
  saveStateRef.current = saveState;

  return {
    property, loadError, saveState, saveError, update, checkpoint, undo, redo, reload: load, saveNow: flush,
    canUndo: undoStack.current.length > 0, canRedo: redoStack.current.length > 0,
  };
}
