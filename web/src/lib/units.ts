import { useEffect, useState } from 'react';

const KEY = 'roomscan.useFeet';
const listeners = new Set<(v: boolean) => void>();

function read() {
  try { return localStorage.getItem(KEY) !== 'false'; } catch { return true; }
}

/** Feet or meters, remembered in this browser and shared across the page. */
export function useUnits(): [boolean, (v: boolean) => void] {
  const [feet, setFeet] = useState(read);
  useEffect(() => {
    listeners.add(setFeet);
    return () => { listeners.delete(setFeet); };
  }, []);
  const set = (v: boolean) => {
    try { localStorage.setItem(KEY, String(v)); } catch { /* not saved */ }
    listeners.forEach((l) => l(v));
  };
  return [feet, set];
}
