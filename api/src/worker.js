// Raise — analytics API on one Cloudflare Worker (copy of cleanx-web without the X Clean-only parts). Data: Supabase Postgres.
//   GET  /config.json       remote app config = defaults (src/config.js) + overrides saved from the admin (KV)
//   POST /events            product analytics batches from the app (src/events.js)
//   POST /webhooks/adapty   payments / subscription status / refunds (src/adapty.js)
//   /admin/api/*            admin API for https://kostiantynchukhas.github.io/raise-site/admin/ (src/admin.js, CORS)
//   GET  /api/geo           visitor country from Cloudflare; nothing stored
// Cron every 15 min: session closing + partitions + retention (SQL analytics_maintenance), KV buffer replay, alerts.
import { json, corsHeaders, withCors } from "./util.js";
import { handleEvents, drainBuffer } from "./events.js";
import { handleAdapty } from "./adapty.js";
import { handleAdmin } from "./admin.js";
import { rpc } from "./supabase.js";
import { serveConfig } from "./config.js";

export default {
  async fetch(request, env, ctx) {
    const { pathname } = new URL(request.url);
    try {
      if (pathname.startsWith("/admin")) {
        if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(request, env) });
        return withCors(await handleAdmin(request, env), request, env);
      }
      if (pathname === "/api/geo" || pathname === "/api/geo/") {
        const cf = request.cf || {};
        return json({ country: cf.country || null, timezone: cf.timezone || null });
      }
      if (pathname === "/config.json") return await serveConfig(request, env);
      if (pathname === "/events") return await handleEvents(request, env);
      if (pathname === "/webhooks/adapty") return await handleAdapty(request, env);
      if (pathname === "/" ) return json({ ok: true, service: "raise-api" });
    } catch (err) {
      console.log("unhandled", pathname, String(err));
      return withCors(json({ error: "internal" }, 500), request, env);
    }
    return json({ error: "not found" }, 404);
  },

  async scheduled(event, env, ctx) {
    const alerts = [];
    try {
      await rpc(env, "analytics_maintenance", {});
      await drainBuffer(env);
      const [h] = await rpc(env, "analytics_report", { name: "health", days: 1 });
      if (h.events_last_day > 50 && h.events_last_hour === 0) alerts.push("⚠️ No events for 60 min (there were events in the last 24h) — app or /events broken?");
      if (h.rejected_last_hour > 20 && h.rejected_last_hour > h.events_last_hour * 0.2) alerts.push(`⚠️ events_rejected spike: ${h.rejected_last_hour} in the last hour`);
      if (h.webhook_errors_last_hour > 0) alerts.push(`⚠️ Adapty webhook errors: ${h.webhook_errors_last_hour} in the last hour`);
      if (h.anomalies_last_hour > 0) alerts.push(`ℹ️ Integration anomalies (unknown customer_user_id etc.): ${h.anomalies_last_hour} in the last hour`);
    } catch (err) {
      alerts.push(`🔥 Analytics DB unreachable: ${String(err).slice(0, 200)}`);
    }
    if (!alerts.length) return;
    console.log(alerts.join(" | "));
    if (env.ALERT_WEBHOOK_URL) {
      const text = `Raise analytics\n${alerts.join("\n")}`;
      ctx.waitUntil(fetch(env.ALERT_WEBHOOK_URL, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, content: text }),
      }).catch(() => {}));
    }
  },
};
