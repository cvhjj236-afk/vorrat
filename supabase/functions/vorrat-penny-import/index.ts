import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';
import { BASE, EXTRACT_VERSION, extractNuxtData, extractProducts, toOffer, weekSlugs, dealSlugs, sha256 } from './core.ts';

declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

class ImportError extends Error {
  retry: boolean;
  constructor(message: string, retry = false) { super(message); this.retry = retry; }
}

async function rpc(name: string, args: Record<string, unknown>) {
  const { data, error } = await sb.rpc(name, args);
  if (error) throw new ImportError('Datenbankschritt fehlgeschlagen: ' + error.code, true);
  return data;
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function fetchHtml(path: string): Promise<string | null> {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const response = await fetch(BASE + path, {
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; VorratBot/1.0; privater Haushalts-Einkaufszettel)', 'Accept': 'text/html' },
      signal: AbortSignal.timeout(25000), redirect: 'follow',
    }).catch(() => null);
    if (response?.ok) {
      const text = await response.text();
      if (text.length > 5_000_000) throw new ImportError('Seite überschreitet die erlaubte Größe.');
      return text;
    }
    if (response && response.status === 404) return null;
    if (attempt < 3) await sleep(1500 * attempt);
    else throw new ImportError(`penny.at antwortet mit HTTP ${response?.status ?? 'Netzwerkfehler'}.`, true);
  }
  return null;
}

// Alle Seiten einer Kategorie einlesen (32 Produkte pro Seite), bis nichts Neues mehr kommt.
async function crawl(slug: string, seen: Map<string, any>): Promise<number> {
  let added = 0;
  for (let page = 1; page <= 15; page++) {
    const html = await fetchHtml(`/kategorie/${slug}?page=${page}`);
    if (!html) break;
    const data = extractNuxtData(html);
    if (!data) throw new ImportError('Penny-Seitenformat unbekannt (kein __NUXT_DATA__).');
    const products = extractProducts(data);
    let fresh = 0;
    for (const p of products) {
      const key = `${p.sku}|${p.price?.validityStart}|${p.price?.validityEnd}`;
      if (!seen.has(key)) { seen.set(key, p); fresh++; }
    }
    added += fresh;
    if (!products.length || !fresh) break;
    await sleep(700);
  }
  return added;
}

async function run() {
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Vienna' });
  const overview = await fetchHtml('/kategorie/alle-angebote-99000000');
  const slugs = [...new Set([...weekSlugs(today), ...(overview ? dealSlugs(overview) : [])])];
  const seen = new Map<string, any>();
  const weeks: { slug: string; products: number }[] = [];
  for (const slug of slugs) {
    const n = await crawl(slug, seen);
    if (n) weeks.push({ slug, products: n });
  }
  if (!seen.size) throw new ImportError('Keine aktuellen PENNY-Angebote gefunden.', true);
  const offers: any[] = [];
  const review: any[] = [];
  const keys = new Set<string>();
  let skipped = 0, expired = 0;
  for (const p of seen.values()) {
    const r = await toOffer(p, today);
    if (r.skipped) skipped++;
    else if (r.expired) expired++;
    else if (r.review) review.push(r.review);
    else if (r.offer && !keys.has(r.offer.product_key)) { keys.add(r.offer.product_key); offers.push(r.offer); }
  }
  if (!offers.length) throw new ImportError('Es konnte kein PENNY-Angebot übernommen werden.');
  const fingerprint = await sha256(JSON.stringify({ v: EXTRACT_VERSION, keys: [...keys].sort() }));
  return { fingerprint, weeks: [...weeks, { skipped_non_food: skipped, expired }], offers, review: review.slice(0, 200) };
}

async function process(runRow: any) {
  try {
    const result = await run();
    const committed = await rpc('vorrat_penny_finish', { p_run_id: runRow.id, p_lease: runRow.lease_id, p_data: result });
    if (!committed) console.log('PENNY-Schritt verworfen: Lease wurde bereits erneuert.');
  } catch (error) {
    const known = error instanceof ImportError;
    const message = known ? error.message : 'Zeitüberschreitung oder unerwarteter Verarbeitungsfehler.';
    try {
      await rpc('vorrat_penny_finish', { p_run_id: runRow.id, p_lease: runRow.lease_id, p_data: { error: message, retry: known ? error.retry : true } });
    } catch { console.error('PENNY-Status konnte nicht gespeichert werden. Wiederaufnahme nach Ablauf der Lease.'); }
  }
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return Response.json({ error: 'POST erforderlich.' }, { status: 405 });
  if (Number(request.headers.get('content-length')) > 4096) return Response.json({ error: 'Anfrage zu groß.' }, { status: 413 });
  try {
    const body = await request.json();
    const authorization = request.headers.get('Authorization');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (body.action === 'start') {
      if (!serviceKey || authorization !== `Bearer ${serviceKey}`) return Response.json({ error: 'Backend-Administrator erforderlich.' }, { status: 403 });
      const runId = await rpc('vorrat_penny_start', { p_source: 'manual' });
      return Response.json({ run_id: runId, message: 'Import gestartet. Status in vorrat_penny_runs.' }, { status: 202 });
    }
    if (typeof body.run_id !== 'string' || !/^[a-f0-9-]{36}$/.test(body.run_id) || typeof body.token !== 'string' || !/^[a-f0-9]{64}$/.test(body.token)) {
      return Response.json({ error: 'Ungültiger Importauftrag.' }, { status: 401 });
    }
    const runRow = await rpc('vorrat_penny_claim', { p_run_id: body.run_id, p_token: body.token });
    if (!runRow) return Response.json({ error: 'Auftrag ungültig oder bereits in Bearbeitung.' }, { status: 409 });
    EdgeRuntime.waitUntil(process(runRow));
    return Response.json({ accepted: true }, { status: 202 });
  } catch {
    return Response.json({ error: 'Importauftrag konnte nicht übernommen werden.' }, { status: 400 });
  }
});
