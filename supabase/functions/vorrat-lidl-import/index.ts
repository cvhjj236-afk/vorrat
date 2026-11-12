import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';
import { flyerApiUrl, slugOf, pageUrl, imageUrl, sha256, validateOffers, pickFallback, promptForPage, RESPONSE_SCHEMA, EXTRACT_VERSION } from './core.ts';

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

async function download(url: string, maxBytes: number, timeout = 20000): Promise<Uint8Array> {
  const response = await fetch(url, { signal: AbortSignal.timeout(timeout), redirect: 'error' });
  if (!response.ok) throw new ImportError(`Quelle antwortet mit HTTP ${response.status}.`, response.status === 429 || response.status >= 500);
  const reader = response.body!.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > maxBytes) { await reader.cancel(); throw new ImportError('Quelldatei überschreitet die erlaubte Größe.'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

async function flyer(slug: string): Promise<any | null> {
  const response = await fetch(flyerApiUrl(slug), { signal: AbortSignal.timeout(20000), redirect: 'error' });
  if (response.status === 404) return null;
  if (!response.ok) throw new ImportError(`Flugblatt-Verzeichnis HTTP ${response.status}.`, response.status >= 500);
  const data = await response.json();
  return data?.success && Array.isArray(data.flyer?.pages) && data.flyer.pages.length ? data.flyer : null;
}

// Flugblatt-Namen folgen dem Muster ab-donnerstag-D-M-flugblatt-grd bzw. ab-montag-D-M-flugblatt-grd.
async function discoverSource(): Promise<string> {
  const today = new Date(new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Vienna' }) + 'T00:00:00Z');
  let best: { slug: string; start: string } | null = null;
  for (let back = -3; back <= 8; back++) {
    const d = new Date(today.getTime() + back * 86400000);
    const dow = d.getUTCDay();
    const day = dow === 4 ? 'donnerstag' : dow === 1 ? 'montag' : null;
    if (!day) continue;
    const slug = `ab-${day}-${d.getUTCDate()}-${d.getUTCMonth() + 1}-flugblatt-grd`;
    const f = await flyer(slug);
    if (!f) continue;
    const end = String(f.offerEndDate || f.endDate || '');
    if (end && end < today.toISOString().slice(0, 10)) continue;
    const start = String(f.offerStartDate || f.startDate || '');
    if (!best || start > best.start) best = { slug, start };
  }
  if (!best) throw new ImportError('Kein aktuelles LIDL-Flugblatt gefunden.');
  return pageUrl(best.slug);
}

async function prepare(run: any) {
  const source = run.source_url || await discoverSource();
  const slug = slugOf(source);
  const f = await flyer(slug);
  if (!f || f.pages.length > 200) throw new ImportError('LIDL-Flugblatt konnte nicht geladen werden.');
  const offerFrom = String(f.offerStartDate || f.startDate || '').slice(0, 10);
  const offerTo = String(f.offerEndDate || f.endDate || '').slice(0, 10) || null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(offerFrom)) throw new ImportError('LIDL-Angebotszeitraum fehlt.');
  const allPages: any[] = f.pages.map((p: any) => ({
    number: p.number, image_url: imageUrl(p.zoom || p.image), text: String(p.keyWords || p.altText || ''),
    offer_from: offerFrom, offer_to: offerTo,
  }));
  allPages.sort((a, b) => a.number - b.number);
  if (allPages.some((page, i) => page.number !== i + 1)) throw new ImportError('Das Seitenverzeichnis ist unvollständig.');
  const pages = run.test_mode ? allPages.slice(0, 5) : allPages;
  const description = `${f.title || f.name}, Angebote ${offerFrom} bis ${offerTo || '?'}`;
  const fingerprint = await sha256(JSON.stringify({ slug, version: EXTRACT_VERSION, description, pages }));
  return {
    edition: slug, source_url: source, description, fingerprint, pages,
    total_pages: allPages.length, model: 'gemini-3.5-flash-lite',
  };
}

function base64(bytes: Uint8Array): string {
  let value = '';
  for (let offset = 0; offset < bytes.length; offset += 8192) value += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  return btoa(value);
}

async function readPage(run: any) {
  const page = run.pages[run.pages_done];
  if (!page || (run.test_mode && page.number > 5)) throw new ImportError('Seite liegt außerhalb des freigegebenen Umfangs.');
  if (page.number === 1) return { page: { number: 1, image_sha256: await sha256('cover-skipped'), offers: [], review: [], usage: {} } };
  const bytes = await download(imageUrl(page.image_url), 8_000_000);
  const mime = bytes[0] === 0xff && bytes[1] === 0xd8 ? 'image/jpeg' : bytes[0] === 0x89 && bytes[1] === 0x50 ? 'image/png' : null;
  if (!mime) throw new ImportError('Seitenquelle ist kein JPEG/PNG.');
  const key = Deno.env.get('GOOGLE_API_KEY');
  if (!key) throw new ImportError('Gemini-Zugang ist im Backend nicht eingerichtet.');
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(run.model)}:generateContent`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
    signal: AbortSignal.timeout(70000),
    body: JSON.stringify({
      contents: [{ role: 'user', parts: [ { text: promptForPage(run, page) }, { inlineData: { mimeType: mime, data: base64(bytes) } } ] }],
      generationConfig: { temperature: 0, responseMimeType: 'application/json', responseJsonSchema: RESPONSE_SCHEMA, maxOutputTokens: 14000 },
    }),
  });
  if (!response.ok) {
    const failure = await response.json().catch(() => ({}));
    const detail = String(failure.error?.message || failure.error?.status || '')
      .split(key).join('[redacted]').replace(/AIza[\w-]+/g, '[redacted]').slice(0, 700);
    throw new ImportError(`Gemini HTTP ${response.status}: ${detail}`, response.status === 429 || response.status >= 500);
  }
  const result = await response.json();
  const candidate = result.candidates?.[0];
  if (candidate?.finishReason !== 'STOP') throw new ImportError('Gemini-Antwort wurde abgebrochen oder blockiert.');
  const content = candidate.content?.parts?.filter((part: any) => !part.thought).map((part: any) => part.text || '').join('');
  const raw = JSON.parse(content || '{}');
  const year = Number(String(page.offer_from).slice(0, 4));
  const prevRows = await sb.from('vorrat_lidl_pages').select('offers').eq('run_id', run.id).lt('page', page.number).order('page', { ascending: false }).limit(8);
  const checked = await validateOffers(raw.offers, page.number, year, pickFallback((prevRows.data || []).map((r: any) => r.offers)) ?? { from: page.offer_from, to: page.offer_to });
  return { page: { number: page.number, image_sha256: await sha256(bytes), ...checked, usage: result.usageMetadata || {} } };
}

async function processStep(run: any) {
  try {
    const result = run.pages.length ? await readPage(run) : await prepare(run);
    const committed = await rpc('vorrat_lidl_finish_step', { p_run_id: run.id, p_lease: run.lease_id, p_data: result });
    if (!committed) console.log('LIDL-Schritt verworfen: Lease wurde bereits erneuert.');
  } catch (error) {
    const known = error instanceof ImportError;
    const message = known ? error.message : error instanceof SyntaxError ? 'Ungültiges JSON in der KI-Antwort.' : 'Zeitüberschreitung oder unerwarteter Verarbeitungsfehler.';
    try {
      await rpc('vorrat_lidl_finish_step', {
        p_run_id: run.id, p_lease: run.lease_id,
        p_data: { error: message, retry: known ? error.retry : !(error instanceof SyntaxError) },
      });
    } catch { console.error('LIDL-Status konnte nicht gespeichert werden. Wiederaufnahme nach Ablauf der Lease.'); }
  }
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return Response.json({ error: 'POST erforderlich.' }, { status: 405 });
  if (Number(request.headers.get('content-length')) > 4096) return Response.json({ error: 'Anfrage zu groß.' }, { status: 413 });
  try {
    const body = await request.json();
    // Backend dashboard invocation uses the service role. User JWTs cannot start imports.
    const authorization = request.headers.get('Authorization');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (body.action === 'start') {
      if (!serviceKey || authorization !== `Bearer ${serviceKey}`) return Response.json({ error: 'Backend-Administrator erforderlich.' }, { status: 403 });
      const runId = await rpc('vorrat_lidl_start', { p_source: 'manual' });
      return Response.json({ run_id: runId, message: 'Import gestartet. Status in vorrat_lidl_runs.' }, { status: 202 });
    }
    if (typeof body.run_id !== 'string' || !/^[a-f0-9-]{36}$/.test(body.run_id) || typeof body.token !== 'string' || !/^[a-f0-9]{64}$/.test(body.token)) {
      return Response.json({ error: 'Ungültiger Importauftrag.' }, { status: 401 });
    }
    const run = await rpc('vorrat_lidl_claim', { p_run_id: body.run_id, p_token: body.token });
    if (!run) return Response.json({ error: 'Auftrag ungültig oder bereits in Bearbeitung.' }, { status: 409 });
    EdgeRuntime.waitUntil(processStep(run));
    return Response.json({ accepted: true }, { status: 202 });
  } catch {
    return Response.json({ error: 'Importauftrag konnte nicht übernommen werden.' }, { status: 400 });
  }
});
