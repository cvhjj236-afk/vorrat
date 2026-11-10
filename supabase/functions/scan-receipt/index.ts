// Supabase Edge Function: Foto von Kassazettel / Einkaufszettel -> Artikelliste (JSON).
// Der API-Key liegt als Secret GOOGLE_API_KEY in Supabase, nie im Browser.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const CATS = ["Obst & Gemüse","Milchprodukte & Eier","Fleisch & Fisch","Brot & Backwaren","Trockenware","Konserven & Gläser","Tiefkühlkost","Getränke","Süßes & Snacks","Gewürze & Saucen","Drogerie","Haushalt","Sonstiges"];
const UNITS = ["Stk","Pkg","g","kg","ml","l","Dose","Flasche","Glas"];
let cachedModel = "";
async function pickModel(key: string): Promise<string> {
  if (cachedModel) return cachedModel;
  try {
    const r = await fetch("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200", { headers: { "x-goog-api-key": key } });
    const j = await r.json();
    const ver = (n: string) => { const m = n.match(/gemini-(\d+(?:\.\d+)?)/); return m ? parseFloat(m[1]) : 0; };
    const c = (j.models ?? [])
      .filter((m: { name: string; supportedGenerationMethods?: string[] }) => /gemini-[\d.]+-flash(-\d+)?$/.test(m.name) && (m.supportedGenerationMethods ?? []).includes("generateContent"))
      .map((m: { name: string }) => m.name.replace("models/", ""))
      .sort((a: string, b: string) => ver(b) - ver(a));
    if (c.length) { cachedModel = c[0]; console.log("model", cachedModel); return cachedModel; }
  } catch (_e) { /* fall through */ }
  return "gemini-2.5-flash";
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: member, error: mErr } = await sb.rpc("vorrat_is_member");
  if (mErr || member !== true) return json({ error: "not_member" }, 403);
  let body: { image?: string; mime?: string; mode?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const img = body.image ?? "";
  const mime = ["image/jpeg", "image/png", "image/webp"].includes(body.mime ?? "") ? body.mime! : "image/jpeg";
  if (!img || img.length > 6_000_000) return json({ error: "image" }, 400);
  const receipt = body.mode !== "list";
  const key = Deno.env.get("GOOGLE_API_KEY");
  if (!key) return json({ error: "no_key" }, 500);
  const prompt = (receipt
    ? "Das Foto zeigt einen Kassabon (Österreich/Deutschland)."
    : "Das Foto zeigt einen handgeschriebenen oder gedruckten Einkaufszettel.") +
    " Lies alle Artikel aus. Antworte NUR mit JSON ohne Erklärung, Format: " +
    '{"shop":string|null,"items":[{"name":string,"qty":number,"unit":string,"price":number|null,"cat":string}]}. ' +
    "name: lesbarer deutscher Artikelname (Abkürzungen auflösen, ohne Mengenangabe). qty: Menge, Standard 1. " +
    "unit: eine aus " + JSON.stringify(UNITS) + ". cat: eine aus " + JSON.stringify(CATS) + ". " +
    (receipt
      ? "price: Gesamtpreis der Zeile in Euro (Zahl) oder null. shop: Name des Geschäfts oder null. Pfand, Rabattzeilen, Summe und Zahlungsinfos weglassen."
      : "price immer null. shop: null, außer ein Geschäft steht auf dem Zettel.");
  const model = Deno.env.get("GEMINI_MODEL") || 'gemini-3.5-flash-lite';
  const gen = (think: boolean) => fetch('https://generativelanguage.googleapis.com/v1beta/models/' + model + ':generateContent', {
    method: 'POST',
    headers: { 'x-goog-api-key': key, 'content-type': 'application/json' },
    signal: AbortSignal.timeout(45000),
    body: JSON.stringify({
      contents: [{ parts: [{ inline_data: { mime_type: mime, data: img } }, { text: prompt }] }],
      generationConfig: think
        ? { responseMimeType: 'application/json', temperature: 0, thinkingConfig: { thinkingLevel: 'minimal' } }
        : { responseMimeType: 'application/json', temperature: 0 },
    }),
  });
  let r: Response;
  try { r = await gen(true); if (r.status === 400) r = await gen(false); for (let i = 0; i < 3 && (r.status === 503 || r.status === 429); i++) { await new Promise((res) => setTimeout(res, 1500 * (i + 1))); r = await gen(true); } }
  catch (_e) { return json({ error: 'timeout' }, 504); }
  if (!r.ok) { const d = (await r.text()).slice(0, 300); console.error("upstream", r.status, d); return json({ error: "upstream", status: r.status, detail: d }, 502); }
  const out = await r.json();
  const text: string = (out.candidates?.[0]?.content?.parts ?? []).map((c: { text?: string }) => c.text ?? "").join("");
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return json({ error: "parse" }, 502);
  try {
    const p = JSON.parse(m[0]);
    const items = (Array.isArray(p.items) ? p.items : []).slice(0, 80).map((i: Record<string, unknown>) => ({
      name: String(i.name ?? "").slice(0, 80),
      qty: typeof i.qty === "number" && i.qty > 0 ? i.qty : 1,
      unit: UNITS.includes(String(i.unit)) ? String(i.unit) : "Stk",
      price: typeof i.price === "number" && i.price >= 0 ? i.price : null,
      cat: CATS.includes(String(i.cat)) ? String(i.cat) : "Sonstiges",
    })).filter((i: { name: string }) => i.name);
    return json({ shop: typeof p.shop === "string" ? p.shop.slice(0, 60) : null, items });
  } catch { return json({ error: "parse" }, 502); }
});
