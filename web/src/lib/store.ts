import { supabase, currentTenantId, PHOTO_BUCKET } from './supabase';
import type { Property } from './model';

export type PropertyRow = {
  id: string;
  name: string;
  data: Property;
  version: number;
  updated_at: string;
  created_at: string;
};

export async function listProperties(): Promise<PropertyRow[]> {
  const { data, error } = await supabase
    .from('roomscan_property')
    .select('id, name, data, version, updated_at, created_at')
    .is('deleted_at', null)
    .order('updated_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as PropertyRow[];
}

export async function getProperty(id: string): Promise<PropertyRow | null> {
  const { data, error } = await supabase
    .from('roomscan_property')
    .select('id, name, data, version, updated_at, created_at')
    .eq('id', id)
    .maybeSingle();
  if (error) throw error;
  return data as PropertyRow | null;
}

export class StaleError extends Error {
  constructor() { super('This walkthrough was changed somewhere else (maybe on the phone). Reload to get the latest copy.'); }
}

/** Saves only if nobody else saved since `version`; returns the new version. */
export async function saveProperty(property: Property, version: number): Promise<number> {
  const { data, error } = await supabase
    .from('roomscan_property')
    .update({ name: property.name, data: property })
    .eq('id', property.id)
    .eq('version', version)
    .select('version');
  if (error) throw error;
  if (!data?.length) throw new StaleError();
  return data[0].version as number;
}

export async function createProperty(property: Property): Promise<PropertyRow> {
  const { data, error } = await supabase
    .from('roomscan_property')
    .insert({ id: property.id, name: property.name, data: property })
    .select('id, name, data, version, updated_at, created_at')
    .single();
  if (error) throw error;
  return data as PropertyRow;
}

export async function deleteProperty(id: string) {
  const { error } = await supabase.from('roomscan_property').update({ deleted_at: new Date().toISOString() }).eq('id', id);
  if (error) throw error;
}

// ── Photos ──────────────────────────────────────────────────────────────────
const photoUrls = new Map<string, Promise<string | null>>();

/** A short-lived link to an item photo the phone uploaded. */
export function photoUrl(propertyId: string, fileName: string) {
  const key = `${propertyId}/${fileName}`;
  if (!photoUrls.has(key)) {
    photoUrls.set(key, (async () => {
      const tenant = await currentTenantId();
      if (!tenant) return null;
      const { data } = await supabase.storage.from(PHOTO_BUCKET).createSignedUrl(`${tenant}/${key}`, 3600);
      return data?.signedUrl ?? null;
    })());
  }
  return photoUrls.get(key)!;
}

export async function uploadPhoto(propertyId: string, file: File): Promise<string> {
  const tenant = await currentTenantId();
  if (!tenant) throw new Error('Your account is not part of a company yet.');
  const ext = file.type === 'image/png' ? 'png' : 'jpg';
  const name = `${crypto.randomUUID().toUpperCase()}.${ext}`;
  const { error } = await supabase.storage.from(PHOTO_BUCKET).upload(`${tenant}/${propertyId}/${name}`, file, { contentType: file.type });
  if (error) throw error;
  return name;
}
