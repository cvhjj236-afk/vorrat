// PENNY-Import: penny.at liefert die Angebote serverseitig gerendert als Nuxt-Daten (__NUXT_DATA__, devalue-Format).
// Kein OCR/Gemini nötig. Alles hier ist reine Logik (testbar ohne Netzwerk).
export const EXTRACT_VERSION = 'penny-1';
export const BASE = 'https://www.penny.at';

export const CATEGORIES = [
  'Obst', 'Gemüse', 'Fleisch & Wurst', 'Fisch & Meeresfrüchte',
  'Milchprodukte & Eier', 'Brot & Backwaren', 'Reis, Nudeln & Trockenwaren',
  'Konserven, Gläser & Saucen', 'Tiefkühlprodukte', 'Getränke', 'Süßes & Snacks',
];

export async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
}

// ---- devalue-Auflösung des Nuxt-Payloads ----
export function extractNuxtData(html: string): unknown[] | null {
  const m = /<script[^>]*id="__NUXT_DATA__"[^>]*>([\s\S]*?)<\/script>/.exec(html);
  if (!m) return null;
  try { const data = JSON.parse(m[1]); return Array.isArray(data) ? data : null; } catch { return null; }
}

const WRAPPERS = new Set(['Reactive', 'ShallowReactive', 'Ref', 'ShallowRef']);

export function extractProducts(data: unknown[]): any[] {
  const cache = new Map<number, unknown>();
  const resolve = (i: number): unknown => {
    if (cache.has(i)) return cache.get(i);
    const v = data[i];
    if (Array.isArray(v)) {
      if (typeof v[0] === 'string' && WRAPPERS.has(v[0]) && typeof v[1] === 'number') {
        const out = resolve(v[1]); cache.set(i, out); return out;
      }
      if (typeof v[0] === 'string' && ['Set', 'Map', 'Date', 'null', 'undefined', 'BigInt', 'RegExp', 'Object'].includes(v[0])) { cache.set(i, null); return null; }
      const out: unknown[] = []; cache.set(i, out);
      for (const x of v) out.push(typeof x === 'number' && x >= 0 ? resolve(x) : null);
      return out;
    }
    if (v && typeof v === 'object') {
      const out: Record<string, unknown> = {}; cache.set(i, out);
      for (const [k, x] of Object.entries(v as Record<string, unknown>)) out[k] = typeof x === 'number' && x >= 0 ? resolve(x) : x;
      return out;
    }
    cache.set(i, v); return v;
  };
  const products: any[] = [];
  data.forEach((v, i) => {
    if (v && typeof v === 'object' && !Array.isArray(v) && 'productId' in (v as object) && 'price' in (v as object)) products.push(resolve(i));
  });
  return products;
}

// ---- Kategorie-Zuordnung (Penny-Baum -> unsere 11 Kategorien) ----
export type Mapped = { category: string } | { skip: string } | { unknown: string };

const SUB: Record<string, string> = {
  'Fleisch': 'Fleisch & Wurst', 'Wurst, Schinken & Speck': 'Fleisch & Wurst',
  'Fisch': 'Fisch & Meeresfrüchte', 'Fisch & Garnelen': 'Tiefkühlprodukte',
  'Milchprodukte': 'Milchprodukte & Eier', 'Käse, Aufstriche & Salate': 'Milchprodukte & Eier', 'Eier': 'Milchprodukte & Eier',
  'Blätterteig & Strudelteig': 'Brot & Backwaren',
  'Kuchen & Co.': 'Brot & Backwaren',
  'Obst': 'Obst', 'Gemüse & Salate': 'Gemüse',
  'Essig & Öle': 'Konserven, Gläser & Saucen', 'Honig, Marmelade & Co.': 'Konserven, Gläser & Saucen',
  'Asia Produkte': 'Konserven, Gläser & Saucen', 'Fertiggerichte': 'Konserven, Gläser & Saucen',
  'Konserven & Sauerwaren': 'Konserven, Gläser & Saucen', 'Saucen & Dressings': 'Konserven, Gläser & Saucen',
  'Gewürze & Würzmittel': 'Konserven, Gläser & Saucen',
  'Reis, Teigwaren & Sugo': 'Reis, Nudeln & Trockenwaren', 'Backen': 'Reis, Nudeln & Trockenwaren',
  'Basisprodukte': 'Reis, Nudeln & Trockenwaren', 'Mehl & Getreideprodukte': 'Reis, Nudeln & Trockenwaren',
  'Zucker & Süßstoffe': 'Reis, Nudeln & Trockenwaren',
};
const TOP: Record<string, string> = {
  'Tiefkühl': 'Tiefkühlprodukte', 'Getränke': 'Getränke', 'Süßes & Salziges': 'Süßes & Snacks',
  'Brot & Gebäck': 'Brot & Backwaren', 'Grundnahrungsmittel': 'Reis, Nudeln & Trockenwaren',
};
const NON_FOOD_TOP = new Set(['Haushalt', 'Non-Food', 'Haustier', 'Pflege']);
const NON_FOOD_SUB = new Set(['Pflanzen & Blumen']);

export function productPath(p: any): string[] | null {
  const paths: any[] = Array.isArray(p?.parentCategories) ? p.parentCategories : [];
  for (const path of paths) {
    const names = (Array.isArray(path) ? path : []).map((x: any) => String(x?.name || ''));
    if (names.length && names[0] !== 'Alle Angebote') return names;
  }
  return null;
}

export function mapCategory(p: any): Mapped {
  const path = productPath(p);
  if (!path) return { unknown: 'Keine Produktkategorie' };
  const [top, sub = ''] = path;
  if (NON_FOOD_TOP.has(top) || NON_FOOD_SUB.has(sub)) return { skip: path.join(' > ') };
  if (top === 'Tiefkühl') return { category: 'Tiefkühlprodukte' };
  // Kühlwaren > Schnelle Küche: Aufback-Brot/Baguette zu Brot, Fertiges zu Konserven/Fertiggerichte.
  if (sub === 'Schnelle Küche') return { category: /baguette|brot|semmel|brötchen|weckerl|gebäck|toast|croissant|ciabatta/i.test(String(p?.name)) ? 'Brot & Backwaren' : 'Konserven, Gläser & Saucen' };
  if (SUB[sub]) return { category: SUB[sub] };
  if (top === 'Obst & Gemüse') return { category: /obst|früchte/i.test(sub) ? 'Obst' : 'Gemüse' };
  if (TOP[top]) return { category: TOP[top] };
  if (top === 'Kühlwaren') return { unknown: path.join(' > ') };
  return { unknown: path.join(' > ') };
}

// ---- Felder ----
const eur = (cents: number) => (cents / 100).toLocaleString('de-AT', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €';
const num = (value: unknown) => String(value).replace('.', ',');

export function cleanName(value: unknown): string {
  return String(value ?? '').replace(/\*+/g, '').replace(/\s+/g, ' ').replace(/\s+([,.;])/g, '$1').trim().slice(0, 200);
}

export function quantityOf(p: any): string | null {
  const amount = String(p?.amount ?? '').trim();
  if (!amount) return null;
  const unit = String(p?.volumeLabelShort ?? '').trim();
  if (unit) return `${num(Number(amount))} ${unit === 'liter' ? 'l' : unit === 'stk' ? 'Stk' : unit}`;
  return `${num(Number(amount))} Stk`;
}

export function unitPriceOf(p: any): string | null {
  const per = p?.price?.regular?.perStandardizedQuantity;
  const unit = String(p?.price?.baseUnitShort || '').trim();
  if (!Number.isFinite(per) || !unit) return null;
  const factor = String(p.price.basePriceFactor ?? '').trim();
  if (!/^\d+$/.test(factor)) return null;
  return `${factor} ${unit} ${eur(per)}`;
}

const isoDate = (v: unknown) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null;

export async function toOffer(p: any, today: string): Promise<{ offer?: any; review?: any; skipped?: string; expired?: boolean }> {
  const mapped = mapCategory(p);
  if ('skip' in mapped) return { skipped: mapped.skip };
  const name = cleanName(p?.name);
  const from = isoDate(p?.price?.validityStart);
  const to = isoDate(p?.price?.validityEnd);
  const regular = Number(p?.price?.regular?.value);
  const loyalty = Number(p?.price?.loyalty?.value);
  const useLoyalty = Number.isFinite(loyalty) && loyalty > 0 && loyalty < regular;
  const cents = useLoyalty ? loyalty : regular;
  const reasons: string[] = [];
  if (!name) reasons.push('Produktname fehlt');
  if ('unknown' in mapped) reasons.push('Kategorie unklar: ' + mapped.unknown);
  if (!Number.isFinite(cents) || cents <= 0) reasons.push('Preis fehlt');
  if (!from || !to || to < from) reasons.push('Gültigkeit fehlt');
  if (reasons.length) return { review: { reasons, sku: p?.sku ?? null, name } };
  if (to! < today) return { expired: true };
  const notes: string[] = [];
  const description = cleanName(p?.descriptionShort);
  if (description) notes.push(description);
  if (useLoyalty) notes.push(`mit jö Karte/App-Gutschein (sonst ${eur(regular)})`);
  if (p?.price?.regular?.promotionText) notes.push(String(p.price.regular.promotionText));
  if (Number(p?.price?.crossed) > 0) notes.push(`statt ${eur(Number(p.price.crossed))}`);
  const brand = cleanName(p?.brand?.name) || null;
  const offer = {
    name, brand, category: (mapped as { category: string }).category,
    price: Math.round(cents) / 100, quantity: quantityOf(p), unit_price: unitPriceOf(p),
    conditions: notes.join('; ') || null, valid_from: from, valid_to: to,
    source_url: p?.slug ? `${BASE}/produkte/${encodeURIComponent(String(p.slug))}` : BASE + '/angebote',
  };
  const key = JSON.stringify([p?.sku ?? name.toLocaleLowerCase('de-AT'), from, to, offer.price, offer.conditions]);
  return { offer: { ...offer, product_key: await sha256(key) } };
}

// Wochen beginnen donnerstags: Kandidaten-Slugs 'angebote-ab-DDMM' für Donnerstage von heute-6 bis heute+8 Tage.
export function weekSlugs(today: string): string[] {
  const base = new Date(today + 'T00:00:00Z');
  const slugs: string[] = [];
  for (let d = -6; d <= 8; d++) {
    const day = new Date(base.getTime() + d * 86400000);
    if (day.getUTCDay() !== 4) continue;
    slugs.push(`angebote-ab-${String(day.getUTCDate()).padStart(2, '0')}${String(day.getUTCMonth() + 1).padStart(2, '0')}`);
  }
  return slugs;
}

// Monats-Deals u. ä. stehen als eigene Unterkategorie auf der Übersichtsseite.
export function dealSlugs(html: string): string[] {
  const found = new Set<string>();
  for (const m of html.matchAll(/(angebote-ab-\d{4}-[a-z0-9-]*(?:monats|deals)[a-z0-9-]*)/g)) found.add(m[1]);
  return [...found];
}
