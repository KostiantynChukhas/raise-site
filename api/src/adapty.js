// POST /webhooks/adapty — payments, subscription status, refunds (TZ 5.5–5.7, 9.3, 9.6).
// Adapty → App settings → Integrations → Webhook:
//   Production & Sandbox URL: https://raise-api.raise-app.workers.dev/webhooks/adapty
//   Authorization header value: the same string as the Worker secret ADAPTY_WEBHOOK_SECRET
// Logic is in SQL (public.analytics_adapty_webhook): dedup by transaction_id, anomalies for unknown customer_user_id.
import { rpc } from "./supabase.js";
import { json } from "./util.js";

export async function handleAdapty(request, env) {
  if (request.method !== "POST") return json({ error: "method" }, 405);
  if (!env.ADAPTY_WEBHOOK_SECRET) return json({ error: "not configured" }, 503);
  const auth = request.headers.get("Authorization") || "";
  if (auth !== env.ADAPTY_WEBHOOK_SECRET && auth !== `Bearer ${env.ADAPTY_WEBHOOK_SECRET}`) return json({ error: "forbidden" }, 401);
  let body;
  try { body = await request.json(); } catch { return json({ error: "bad json" }, 400); }
  if (!body || !body.event_type) return json({ ok: true }); // Adapty's verification request

  try {
    const status = await rpc(env, "analytics_adapty_webhook", { body });
    return json({ ok: true, status });
  } catch (err) {
    console.log("adapty webhook failed:", body.event_type, String(err));
    await rpc(env, "analytics_log_webhook_error", { event_type: String(body.event_type), error: String(err) }).catch(() => {});
    return json({ error: "processing failed" }, 500); // non-200 → Adapty retries; SQL dedup keeps it idempotent
  }
}
