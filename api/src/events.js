// POST /events — batch ingest from the iOS app (TZ 9.1). Validation/dedup/sessions happen in SQL
// (public.analytics_ingest). If Supabase is unavailable the batch is parked in KV and replayed by cron (TZ 2.3).
import { rpc } from "./supabase.js";
import { json } from "./util.js";

export async function handleEvents(request, env) {
  if (request.method !== "POST") return json({ error: "method" }, 405);
  if (request.headers.get("X-App-Key") !== env.APP_KEY) return json({ error: "forbidden" }, 403);
  let body;
  try { body = await request.json(); } catch { return json({ error: "bad json" }, 400); }
  if (!body || !Array.isArray(body.events)) return json({ error: "events[] required" }, 400);
  body.events = body.events.slice(0, 500);
  const country = request.cf?.country || null;
  try {
    return json(await rpc(env, "analytics_ingest", { payload: body, country }));
  } catch (err) {
    console.log("ingest failed, buffering:", String(err));
    if (env.BUFFER) {
      await env.BUFFER.put(`buf:${Date.now()}:${crypto.randomUUID()}`, JSON.stringify({ body, country }),
        { expirationTtl: 60 * 60 * 24 * 7 });
      return json({ buffered: true }, 202);
    }
    return json({ error: "unavailable" }, 503); // the app keeps the batch and retries
  }
}

export async function drainBuffer(env, limit = 1000) {
  if (!env.BUFFER) return 0;
  const list = await env.BUFFER.list({ prefix: "buf:", limit });
  let done = 0;
  for (const k of list.keys) {
    const raw = await env.BUFFER.get(k.name);
    if (!raw) continue;
    try {
      const { body, country } = JSON.parse(raw);
      await rpc(env, "analytics_ingest", { payload: body, country });
      await env.BUFFER.delete(k.name);
      done++;
    } catch (e) { console.log("replay failed", k.name, String(e)); break; }
  }
  return done;
}
