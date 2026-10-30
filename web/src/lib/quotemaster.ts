// Creating a QuoteMaster quote from a walkthrough. RoomScan shares QuoteMaster's database, so
// this writes the same records QuoteMaster's own "New Opportunity" wizard does, scoped to the
// user's company by the database's row rules.
import { supabase } from './supabase';
import type { Item, Room } from './model';

export type Product = {
  id: string; name: string; sku: string | null; category: string | null; product_type: string | null;
  description: string | null; list_price: number | null; msrp: number | null; base_cost: number | null;
  image_url: string | null; image_urls: string[] | null; display_image_urls: string[] | null;
};
export type Client = {
  id: string; name: string; email: string | null; company: string | null; phone: string | null;
  address: string | null; city: string | null; state: string | null; zip: string | null;
  tax_rate: number | null; is_tax_exempt: boolean | null;
};
export type Template = {
  id: string; name: string; description: string | null; layout: string | null; is_default: boolean | null;
  primary_color: string | null; secondary_color: string | null; font_header: string | null; font_body: string | null;
  font_line_items: string | null; font_totals: string | null; logo_url: string | null; blocks: unknown[] | null;
  default_notes: string | null; default_terms: string | null;
};

export const CRM_STAGES = [
  { value: 'lead', label: 'Lead' },
  { value: 'qualified', label: 'Qualified' },
  { value: 'proposal', label: 'Proposal' },
  { value: 'negotiation', label: 'Negotiation' },
];
export const LEAD_SOURCES = [
  { value: 'referral', label: 'Referral' }, { value: 'website', label: 'Website' },
  { value: 'cold_call', label: 'Cold Call' }, { value: 'email_campaign', label: 'Email Campaign' },
  { value: 'trade_show', label: 'Trade Show' }, { value: 'social_media', label: 'Social Media' },
  { value: 'existing_client', label: 'Existing Client' }, { value: 'other', label: 'Other' },
];

export async function loadProducts(): Promise<Product[]> {
  const { data, error } = await supabase
    .from('product')
    .select('id, name, sku, category, product_type, description, list_price, msrp, base_cost, image_url, image_urls, display_image_urls')
    .neq('is_active', false)
    .order('name')
    .limit(5000);
  if (error) throw error;
  return (data ?? []) as Product[];
}

export async function searchClients(query: string): Promise<Client[]> {
  let q = supabase
    .from('client')
    .select('id, name, email, company, phone, address, city, state, zip, tax_rate, is_tax_exempt')
    .neq('is_active', false)
    .order('name')
    .limit(20);
  if (query.trim()) q = q.or(`name.ilike.%${query.trim().replace(/[%,()]/g, '')}%,company.ilike.%${query.trim().replace(/[%,()]/g, '')}%`);
  const { data, error } = await q;
  if (error) throw error;
  return (data ?? []) as Client[];
}

export async function loadTemplates(): Promise<Template[]> {
  const { data, error } = await supabase
    .from('quote_template')
    .select('id, name, description, layout, is_default, primary_color, secondary_color, font_header, font_body, font_line_items, font_totals, logo_url, blocks, default_notes, default_terms')
    .neq('is_active', false)
    .order('name');
  if (error) throw error;
  return (data ?? []) as Template[];
}

/** Same format as QuoteMaster's generateQuoteNumber. */
export function quoteNumber() {
  const timestamp = Date.now().toString(36).toUpperCase();
  const random = Math.random().toString(36).substring(2, 6).toUpperCase();
  return `QT-${timestamp}-${random}`;
}

export function accessToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(36).padStart(2, '0')).join('');
}

/** One quote line as the wizard builds it. */
export type Line = {
  key: string;
  roomId: string;
  itemIds: string[];
  name: string;
  description: string;
  category: string;
  quantity: number;
  productId: string;
  unitPrice: number;
  unitCost: number;
  matchNote?: string;
};

/** Turns chosen walkthrough items into quote lines, optionally merging identical ones within a room. */
export function linesFor(rooms: Room[], chosen: Set<string>, combine: boolean): Line[] {
  const lines: Line[] = [];
  for (const room of rooms) {
    const items = room.items.filter((i) => chosen.has(i.id));
    const groups = new Map<string, Item[]>();
    for (const i of items) {
      const key = combine ? `${i.name.trim().toLowerCase()}|${i.category}|${i.isRequested}` : i.id;
      groups.set(key, [...(groups.get(key) ?? []), i]);
    }
    for (const [key, group] of groups) {
      const first = group[0];
      const notes = [...new Set(group.map((i) => i.notes).filter(Boolean))].join('; ');
      lines.push({
        key: `${room.id}|${key}`,
        roomId: room.id,
        itemIds: group.map((i) => i.id),
        name: first.name,
        description: [first.isRequested ? 'Customer request' : `Existing: ${first.condition.replace(/([A-Z])/g, ' $1').toLowerCase()}`, notes].filter(Boolean).join('. '),
        category: first.category,
        quantity: group.reduce((s, i) => s + (i.quantity || 1), 0),
        productId: '',
        unitPrice: 0,
        unitCost: 0,
      });
    }
  }
  return lines;
}

export type QuoteDraft = {
  propertyId: string;
  title: string;
  client: {
    existingId?: string; saveNew: boolean;
    name: string; email: string; company: string; phone: string;
    address: string; city: string; state: string; zip: string;
    taxRate: number; taxExempt: boolean;
  };
  crm: { stage: string; leadSource: string; probability: number | null; notes: string };
  template: Template | null;
  groupByRoom: boolean;
  rooms: Room[];
  lines: Line[];
  products: Map<string, Product>;
  notes: string;
};

export function totals(lines: Line[], taxRate: number) {
  const subtotal = lines.reduce((s, l) => s + l.unitPrice * l.quantity, 0);
  const cost = lines.reduce((s, l) => s + l.unitCost * l.quantity, 0);
  const tax = subtotal * (taxRate / 100);
  const total = subtotal + tax;
  return {
    subtotal: round(subtotal), cost: round(cost), tax: round(tax), total: round(total),
    margin: total > 0 ? round(((total - cost) / total) * 100) : 0,
  };
}
const round = (n: number) => Math.round(n * 100) / 100;

function quoteItems(d: QuoteDraft) {
  const items: Record<string, unknown>[] = [];
  const stamp = Date.now();
  let n = 0;
  const uid = () => crypto.randomUUID();
  for (const room of d.rooms) {
    const lines = d.lines.filter((l) => l.roomId === room.id);
    if (!lines.length) continue;
    if (d.groupByRoom) items.push({ item_type: 'header', product_name: room.name, _id: `item-roomscan-${stamp}-${n++}`, item_uid: uid() });
    for (const l of lines) {
      const p = l.productId ? d.products.get(l.productId) : undefined;
      const lineTotal = l.unitPrice * l.quantity;
      const lineCost = l.unitCost * l.quantity;
      items.push({
        item_type: 'product',
        product_id: p?.id,
        product_name: p?.name ?? l.name,
        sku: p?.sku ?? '',
        description: p ? [p.description, l.description].filter(Boolean).join('\n') : l.description,
        quantity: l.quantity,
        unit_cost: l.unitCost,
        unit_price: l.unitPrice,
        discount_percent: 0,
        discount_amount: 0,
        is_taxable: true,
        image_url: p?.image_url ?? '',
        image_urls: p?.image_urls?.length ? p.image_urls : p?.image_url ? [p.image_url] : [],
        display_image_urls: p?.display_image_urls?.length ? p.display_image_urls : p?.image_url ? [p.image_url] : [],
        item_type_tag: p?.product_type ?? '',
        category: p?.category ?? l.category,
        line_total: lineTotal,
        line_cost: lineCost,
        profit: lineTotal - lineCost,
        margin_percent: lineTotal > 0 ? ((lineTotal - lineCost) / lineTotal) * 100 : 0,
        markup_percent: lineCost > 0 ? ((lineTotal - lineCost) / lineCost) * 100 : 0,
        _id: `item-roomscan-${stamp}-${n++}`,
        item_uid: uid(),
      });
    }
  }
  return items;
}

/** Creates the draft quote (and the client, if asked) and returns the quote's id. */
export async function createQuote(d: QuoteDraft): Promise<string> {
  const c = d.client;
  const taxRate = c.taxExempt ? 0 : c.taxRate;
  const t = totals(d.lines, taxRate);
  const tpl = d.template;
  const template = tpl ? {
    template_id: tpl.id,
    primary_color: tpl.primary_color, secondary_color: tpl.secondary_color,
    font_header: tpl.font_header, font_body: tpl.font_body, font_line_items: tpl.font_line_items, font_totals: tpl.font_totals,
    logo_url: tpl.logo_url,
    custom_layout: tpl.blocks?.length ? tpl.blocks : undefined,
    terms_conditions: tpl.default_terms || '',
    layout: tpl.layout || 'classic',
  } : { layout: 'classic' };

  const { data: quote, error } = await supabase.from('quote').insert({
    quote_number: quoteNumber(),
    title: d.title,
    client_name: c.name || 'No Client',
    client_email: c.email, client_company: c.company, client_phone: c.phone,
    client_address: c.address, client_city: c.city, client_state: c.state, client_zip: c.zip,
    status: 'draft',
    crm_stage: d.crm.stage,
    lead_source: d.crm.leadSource || null,
    probability: d.crm.probability ?? null,
    probability_amount: d.crm.probability != null ? round((t.total * d.crm.probability) / 100) : null,
    sales_notes: d.crm.notes,
    client_access_token: accessToken(),
    items: quoteItems(d),
    subtotal: t.subtotal,
    discount_total: 0,
    tax_rate: taxRate,
    tax_amount: t.tax,
    total: t.total,
    total_cost: t.cost,
    profit_margin: t.margin,
    notes: [tpl?.default_notes, d.notes].filter(Boolean).join('\n\n'),
    ...template,
  }).select('id').single();
  if (error) throw error;

  if (!c.existingId && c.saveNew && c.name.trim()) {
    // Not fatal: the quote already exists.
    await supabase.from('client').insert({
      name: c.name, email: c.email, company: c.company, phone: c.phone,
      address: c.address, city: c.city, state: c.state, zip: c.zip,
      tax_rate: c.taxRate, is_tax_exempt: c.taxExempt, notes: 'Added from a RoomScan walkthrough.',
    });
  }

  await supabase.from('roomscan_quote_link').insert({
    property_id: d.propertyId,
    quote_id: quote.id,
    item_ids: d.lines.flatMap((l) => l.itemIds),
  });
  return quote.id as string;
}

export async function quoteLinks(propertyId: string) {
  const { data } = await supabase
    .from('roomscan_quote_link')
    .select('quote_id, item_ids, created_at, quote:quote_id (quote_number, title, status, total)')
    .eq('property_id', propertyId)
    .order('created_at', { ascending: false });
  return (data ?? []) as unknown as {
    quote_id: string; item_ids: string[]; created_at: string;
    quote: { quote_number: string; title: string; status: string; total: number } | null;
  }[];
}
