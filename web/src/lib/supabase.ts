import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
if (!url || !key) throw new Error('Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (see .env.example).');

export const supabase = createClient(url, key);
export const QUOTEMASTER_URL = (import.meta.env.VITE_QUOTEMASTER_URL as string) || 'https://quotemaster-black.vercel.app';
export const PHOTO_BUCKET = 'roomscan-photos';

/** Calls the roomscan-ai server function. */
export async function callAI<T>(action: string, body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke('roomscan-ai', { body: { action, ...body } });
  if (error) {
    let message = error.message;
    try {
      const detail = await (error as { context?: Response }).context?.json();
      if (detail?.error) message = detail.error;
    } catch { /* keep the generic message */ }
    throw new Error(message);
  }
  return data as T;
}

let tenantCache: Promise<string | null> | null = null;
/** The signed-in user's company id in QuoteMaster. */
export function currentTenantId() {
  return (tenantCache ??= (async () => {
    const { data } = await supabase.rpc('current_tenant_id');
    return (data as string) ?? null;
  })());
}
export const clearTenantCache = () => { tenantCache = null; };
