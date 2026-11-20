// Arbeitet die Foto-Warteschlange ab (vorrat_scan_jobs). Aufruf nur per pg_net mit Einmal-Token aus vorrat_scan_tick().
// Ein Versuch pro Aufruf; bei Fehlern entscheidet vorrat_scan_finish (Wiederholung in 5 Min., max. 24 Versuche).
// Prompt/Kategorien müssen mit scan-receipt übereinstimmen.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';

declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
const CATS = ['Obst & Gemüse','Milchprodukte & Eier','Fleisch & Fisch','Brot & Backwaren','Trockenware','Konserven & Gläser','Tiefkühlkost','Getränke','Süßes & Snacks','Gewürze & Saucen','Drogerie','Haushalt','Sonstiges'];
const UNITS = ['Stk','Pkg','g','kg','ml','l','Dose','Flasche','Glas'];

type Outcome = { result: unknown } | { error: string; retry: boolean };

async function analyze(image: string, mode: string): Promise<Outcome> {
  const key = Deno.env.get('GOOGLE_API_KEY');
  if (!key) return { error: 'API-Key fehlt', retry: true };
  const receipt = mode !== 'list';
  const prompt = (receipt ? 'Das Foto zeigt einen Kassabon (Österreich/Deutschland).' : 'Das Foto zeigt einen handgeschriebenen oder gedruckten Einkaufszettel.') +
    ' Lies alle Artikel aus. Antworte NUR mit JSON ohne Erklärung, Format: ' +
    '{"shop":string|null,"items":[{"name":string,"qty":number,"unit":string,"price":number|null,"cat":string}]}. ' +
    'name: lesbarer deutscher Artikelname (Abkürzungen auflösen, ohne Mengenangabe). qty: Menge, Standard 1. ' +
    'unit: eine aus ' + JSON.stringify(UNITS) + '. cat: eine aus ' + JSON.stringify(CATS) + '. ' +
    (receipt ? 'price: Gesamtpreis der Zeile in Euro (Zahl) oder null. shop: Name des Geschäfts oder null. Pfand, Rabattzeilen, Summe und Zahlungsinfos weglassen.'
      : 'price immer null. shop: null, außer ein Geschäft steht auf dem Zettel.');
  const model = Deno.env.get('GEMINI_MODEL') || 'gemini-3.5-flash-lite';
  const gen = (think: boolean) => fetch('https://generativelanguage.googleapis.com/v1beta/models/' + model + ':generateContent', {
    method: 'POST', headers: { 'x-goog-api-key': key, 'content-type': 'application/json' }, signal: AbortSignal.timeout(60000),
    body: JSON.stringify({
      contents: [{ parts: [{ inline_data: { mime_type: 'image/jpeg', data: image } }, { text: prompt }] }],
      generationConfig: think ? { responseMimeType: 'application/json', temperature: 0, thinkingConfig: { thinkingLevel: 'minimal' } } : { responseMimeType: 'application/json', temperature: 0 },
    }),
  });
  let r: Response;
  try { r = await gen(true); if (r.status === 400) r = await gen(false); }
  catch { return { error: 'Zeitüberschreitung bei Gemini', retry: true }; }
  if (!r.ok) return { error: `Gemini HTTP ${r.status}`, retry: true };
  try {
    const out = await r.json();
    const text: string = (out.candidates?.[0]?.content?.parts ?? []).map((c: { text?: string }) => c.text ?? '').join('');
    const m = text.match(/\{[\s\S]*\}/);
    if (!m) return { error: 'Antwort nicht lesbar', retry: true };
    const p = JSON.parse(m[0]);
    const items = (Array.isArray(p.items) ? p.items : []).slice(0, 80).map((i: Record<string, unknown>) => ({
      name: String(i.name ?? '').slice(0, 80), qty: typeof i.qty === 'number' && i.qty > 0 ? i.qty : 1,
      unit: UNITS.includes(String(i.unit)) ? String(i.unit) : 'Stk', price: typeof i.price === 'number' && i.price >= 0 ? i.price : null,
      cat: CATS.includes(String(i.cat)) ? String(i.cat) : 'Sonstiges',
    })).filter((i: { name: string }) => i.name);
    return { result: { shop: typeof p.shop === 'string' ? p.shop.slice(0, 60) : null, items } };
  } catch { return { error: 'Antwort nicht lesbar', retry: true }; }
}

async function process(job: { id: string; mode: string; image: string; lease_id: string }) {
  let outcome: Outcome;
  try { outcome = await analyze(job.image, job.mode); }
  catch { outcome = { error: 'Unerwarteter Fehler', retry: true }; }
  const data = 'result' in outcome ? { result: outcome.result } : { error: outcome.error, retry: outcome.retry };
  // Ergebnis speichern; schlägt das fehl, läuft die Lease ab und der Auftrag kommt in 3 Min. wieder dran (Foto bleibt erhalten).
  for (let i = 0; i < 3; i++) {
    const { error } = await sb.rpc('vorrat_scan_finish', { p_id: job.id, p_lease: job.lease_id, p_data: data });
    if (!error) return;
    await new Promise(r => setTimeout(r, 1000 * (i + 1)));
  }
  console.error('Scan-Ergebnis konnte nicht gespeichert werden:', job.id);
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return Response.json({ error: 'POST erforderlich.' }, { status: 405 });
  try {
    const body = await request.json();
    if (typeof body.job_id !== 'string' || !/^[a-f0-9-]{36}$/.test(body.job_id) || typeof body.token !== 'string' || !/^[a-f0-9]{64}$/.test(body.token)) {
      return Response.json({ error: 'Ungültiger Auftrag.' }, { status: 401 });
    }
    const { data: job, error } = await sb.rpc('vorrat_scan_claim', { p_id: body.job_id, p_token: body.token });
    if (error || !job) return Response.json({ error: 'Auftrag ungültig oder bereits in Bearbeitung.' }, { status: 409 });
    EdgeRuntime.waitUntil(process(job));
    return Response.json({ accepted: true }, { status: 202 });
  } catch { return Response.json({ error: 'Anfrage fehlerhaft.' }, { status: 400 }); }
});
