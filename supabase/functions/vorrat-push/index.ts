// Verschickt fällige Push-Erinnerungen. Aufruf nur durch vorrat_push_tick() mit Einmal-Token (JWT-Prüfung aus).
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let token = "";
  try { token = String((await req.json()).token ?? ""); } catch { return json({ error: "body" }, 400); }
  if (!/^[0-9a-f]{64}$/.test(token)) return json({ error: "token" }, 400);

  const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY");
  if (!pub || !priv) return json({ error: "vapid_missing" }, 500);
  webpush.setVapidDetails("mailto:noreply@vorrat.invalid", pub, priv);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await sb.rpc("vorrat_push_claim", { p_token: token });
  if (error) return json({ error: "claim" }, 500);
  if (!Array.isArray(data)) return json({ error: "token_invalid" }, 403);

  let sent = 0, dropped = 0, failed = 0;
  for (const m of data as { title: string; body: string; subs: { endpoint: string; p256dh: string; auth: string }[] }[]) {
    const payload = JSON.stringify({ title: m.title, body: m.body });
    for (const s of m.subs) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600 });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) { await sb.rpc("vorrat_push_drop", { p_endpoint: s.endpoint }); dropped++; }
        else { failed++; console.error("push failed", code); }
      }
    }
  }
  return json({ sent, dropped, failed });
});
