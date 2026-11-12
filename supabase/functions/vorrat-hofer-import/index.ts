import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';
import { bootstrapData, sourceUrl, imageUrl, sha256, validateOffers, pickFallback, promptForPage, RESPONSE_SCHEMA, EXTRACT_VERSION } from './core.ts';

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

async function text(url: string): Promise<string> {
  return new TextDecoder().decode(await download(url, 3_000_000));
}

async function discoverSource(): Promise<string> {
  const html = await text('https://www.hofer.at/flugblatt');
  const links = [...new Set(html.match(/https:\/\/katalog\.hofer\.at\/flipbook_kw\d{2}_\d{2}_0/g) || [])];
  links.sort((a, b) => {
    const rank = (url: string) => { const m = url.match(/kw(\d{2})_(\d{2})/)!; return Number(m[2]) * 100 + Number(m[1]); };
    return rank(b) - rank(a);
  });
  if (!links.length) throw new ImportError('Kein HOFER-Wochenflugblatt auf der offiziellen Seite gefunden.');
  return sourceUrl(links[0]);
}


async function prepare(run: any) {
  const source = run.source_url ? sourceUrl(run.source_url) : await discoverSource();
  const data = bootstrapData(await text(source));
  const edition = source.split('/').pop()!;
  if (data.slug !== edition || data.groupId !== 95552 || !Number.isInteger(data.numPages) || data.numPages < 1 || data.numPages > 200) {
    throw new ImportError('HOFER-Publikation konnte nicht eindeutig geprüft werden.');
  }
  const allPages: any[] = [];
  for (let batch = 1; batch <= 20; batch++) {
    const response = await fetch(`${source}/spreads.json?page=${batch}`, { signal: AbortSignal.timeout(20000), redirect: 'error' });
    if (!response.ok) throw new ImportError(`Seitenverzeichnis HTTP ${response.status}.`, response.status >= 500);
    const spreads = await response.json();
    if (!Array.isArray(spreads)) throw new ImportError('Unbekanntes Seitenverzeichnis.');
    for (const spread of spreads) {
      for (const page of spread.pages || []) {
        allPages.push({ number: page.number, image_url: imageUrl(page.images?.at2000 || page.images?.at1600), text: String(page.text || '') });
      }
    }
    if (!response.headers.get('X-Next-Page')) break;
  }
  allPages.sort((a, b) => a.number - b.number);
  if (allPages.length !== data.numPages || allPages.some((page, i) => page.number !== i + 1)) throw new ImportError('Das Seitenverzeichnis ist unvollständig.');
  const pages = run.test_mode ? allPages.slice(0, 5) : allPages;
  const fingerprint = await sha256(JSON.stringify({ edition, version: EXTRACT_VERSION, description: data.config.description, pages }));
  return {
    edition, source_url: source, description: data.config.description, fingerprint, pages,
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
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new ImportError('Seitenquelle ist kein JPEG.');
  const key = Deno.env.get('GOOGLE_API_KEY');
  if (!key) throw new ImportError('Gemini-Zugang ist im Backend nicht eingerichtet.');
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(run.model)}:generateContent`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
    signal: AbortSignal.timeout(70000),
    body: JSON.stringify({
      contents: [{ role: 'user', parts: [ { text: promptForPage(run, page) }, { inlineData: { mimeType: 'image/jpeg', data: base64(bytes) } } ] }],
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
  const year = 2000 + Number(run.edition.match(/_(\d{2})_0$/)[1]);
  const prevRows = await sb.from('vorrat_hofer_pages').select('offers').eq('run_id', run.id).lt('page', page.number).order('page', { ascending: false }).limit(8);
  const checked = await validateOffers(raw.offers, page.number, year, pickFallback((prevRows.data || []).map((r: any) => r.offers)));
  return { page: { number: page.number, image_sha256: await sha256(bytes), ...checked, usage: result.usageMetadata || {} } };
}

async function processStep(run: any) {
  try {
    const result = run.pages.length ? await readPage(run) : await prepare(run);
    const committed = await rpc('vorrat_hofer_finish_step', { p_run_id: run.id, p_lease: run.lease_id, p_data: result });
    if (!committed) console.log('HOFER-Schritt verworfen: Lease wurde bereits erneuert.');
  } catch (error) {
    const known = error instanceof ImportError;
    const message = known ? error.message : error instanceof SyntaxError ? 'Ungültiges JSON in der KI-Antwort.' : 'Zeitüberschreitung oder unerwarteter Verarbeitungsfehler.';
    try {
      await rpc('vorrat_hofer_finish_step', {
        p_run_id: run.id, p_lease: run.lease_id,
        p_data: { error: message, retry: known ? error.retry : !(error instanceof SyntaxError) },
      });
    } catch { console.error('HOFER-Status konnte nicht gespeichert werden. Wiederaufnahme nach Ablauf der Lease.'); }
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
      const runId = await rpc('vorrat_hofer_start', { p_source: 'manual' });
      return Response.json({ run_id: runId, message: 'Import gestartet. Status in vorrat_hofer_runs.' }, { status: 202 });
    }
    if (typeof body.run_id !== 'string' || !/^[a-f0-9-]{36}$/.test(body.run_id) || typeof body.token !== 'string' || !/^[a-f0-9]{64}$/.test(body.token)) {
      return Response.json({ error: 'Ungültiger Importauftrag.' }, { status: 401 });
    }
    const run = await rpc('vorrat_hofer_claim', { p_run_id: body.run_id, p_token: body.token });
    if (!run) return Response.json({ error: 'Auftrag ungültig oder bereits in Bearbeitung.' }, { status: 409 });
    EdgeRuntime.waitUntil(processStep(run));
    return Response.json({ accepted: true }, { status: 202 });
  } catch {
    return Response.json({ error: 'Importauftrag konnte nicht übernommen werden.' }, { status: 400 });
  }
});
