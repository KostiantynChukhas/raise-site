// /admin/api — Raise admin API (dashboard: raise-site/admin on GitHub Pages). Growth dashboard (organic vs paid, funnels, revenue, cohorts, retention, insights) + app config + ad spend import.
// Protected by the ADMIN_TOKEN secret. Reports are SQL functions in Supabase and return no PII (TZ 2.6):
//   public.analytics_report(name, days)                     — 0001_init.sql (health, mrr, cac, …)
//   public.analytics_growth(p_name, p_days, p_segment)      — 0002_growth_reports.sql (kpis, daily, funnel, …)
//   public.analytics_release(p_name, p_days, p_segment)     — 0003_security_check.sql (release_versions, trial_push, …)
//   public.analytics_billing(p_name, p_days, p_segment)     — 0004_billing_winback.sql (billing_winback)
//   public.analytics_ab(p_name, p_days, p_segment, p_country, p_test) — 0005_ab_paywall.sql (ab_summary, ab_funnel)
//   public.analytics_crm(p_name, p_days, p_query, p_user, p_filter, p_limit) — 0006_crm_feedback.sql (users, user, feedback)
//   public.analytics_ab_rating(p_name, p_days)              — 0016_ab_rating_new_users.sql (rating_summary: A/B of the rating screen)
import { rpc } from "./supabase.js";
import { drainBuffer } from "./events.js";
import { json } from "./util.js";
import { adminConfig } from "./config.js";
import ADMIN_HTML from "../../admin/index.html";

const GROWTH = new Set(["kpis", "daily", "funnel", "sources", "countries", "products", "trial_cohorts", "ltv", "retention",
  "time_to_purchase", "paywall", "features", "versions", "churn", "onboarding", "engagement", "timing", "country_list"]);
// 0003_security_check.sql — releases: trial push, re-engagement pushes, Security Check per app version
const RELEASE = new Set(["release_versions", "trial_push", "push_opens", "security_issues", "security_actions"]);
// 0004_billing_winback.sql — payment problems + win-back
const BILLING = new Set(["billing_winback"]);
// 0005_ab_paywall.sql — paywall A/B test via /admin → Настройки (ab_*); optional ?ab_test=<ab_test_name>
const AB = new Set(["ab_summary", "ab_funnel"]);
const SEGMENTS = new Set(["all", "organic", "paid", "unknown"]);
// 0006_crm_feedback.sql — CRM: user list, user card, in-app feedback
const CRM = new Set(["users", "user", "feedback", "feedback_summary", "version_list", "links"]);

export async function handleAdmin(request, env) {
  const url = new URL(request.url);
  // The dashboard page (same file as raise-site/admin/index.html on GitHub Pages, bundled at build time).
  if (url.pathname === "/admin" || url.pathname === "/admin/") {
    return new Response(ADMIN_HTML, {
      headers: { "Content-Type": "text/html; charset=utf-8", "X-Robots-Tag": "noindex", "Cache-Control": "no-store" },
    });
  }
  if (!env.ADMIN_TOKEN || request.headers.get("Authorization") !== `Bearer ${env.ADMIN_TOKEN}`) return json({ error: "unauthorized" }, 401);

  const days = Math.min(Math.max(parseInt(url.searchParams.get("days") || "30", 10) || 30, 1), 730);
  const segment = SEGMENTS.has(url.searchParams.get("segment")) ? url.searchParams.get("segment") : "all";
  // ISO country code (US, DE, …) or "??" for unknown; empty = all countries
  const country = /^([A-Za-z]{2}|\?\?)$/.test(url.searchParams.get("country") || "") ? url.searchParams.get("country").toUpperCase() : null;

  // Calendar range (0007_date_range.sql): ?from=<ISO>&to=<ISO, exclusive> — the browser's local midnights.
  // Sent to SQL as headers, so the report functions keep their signatures; without them = last `days` days.
  const rf = Date.parse(url.searchParams.get("from") || ""), rt = Date.parse(url.searchParams.get("to") || "");
  const range = rf && rt && rt > rf && rt - rf <= 731 * 86400000
    ? { "X-Range-From": new Date(rf).toISOString(), "X-Range-To": new Date(rt).toISOString() } : undefined;

  // A/B report filter: test name (empty = any test)
  const abTest = (url.searchParams.get("ab_test") || "").slice(0, 64) || null;

  if (url.pathname === "/admin/api/config") return await adminConfig(request, env);

  // Replay batches parked in KV right now (normally the cron does it every 15 min).
  if (url.pathname === "/admin/api/drain" && request.method === "POST") {
    const left = env.BUFFER ? (await env.BUFFER.list({ prefix: "buf:", limit: 1000 })).keys.length : 0;
    const done = await drainBuffer(env, 300);
    return json({ parked_before: left, replayed: done });
  }

  // App version filter for the CRM (0011): ?version=2.4
  const version = (url.searchParams.get("version") || "").slice(0, 32) || null;

  // Delete a review → the whole rating of that user (0011): POST {event_id}
  if (url.pathname === "/admin/api/crm/delete" && request.method === "POST") {
    let body; try { body = await request.json(); } catch { return json({ error: "bad body" }, 400); }
    const id = String(body?.event_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: "bad event_id" }, 400);
    try { return json({ deleted: await rpc(env, "analytics_crm_delete", { p_event_id: id }) }); }
    catch (err) { return json({ error: String(err).slice(0, 300) }, 502); }
  }
  // Delete a whole star bucket in the current period / version (0011): POST {stars}
  if (url.pathname === "/admin/api/crm/delete_stars" && request.method === "POST") {
    let body; try { body = await request.json(); } catch { return json({ error: "bad body" }, 400); }
    const stars = parseInt(body?.stars, 10);
    if (!(stars >= 1 && stars <= 5)) return json({ error: "bad stars" }, 400);
    try { return json({ users: await rpc(env, "analytics_crm_delete_stars", { p_stars: stars, p_days: days, p_version: version }, range) }); }
    catch (err) { return json({ error: String(err).slice(0, 300) }, 502); }
  }

  // Clear the free-gift funnel in the current period / version (0014): POST {step: shown|accepted|declined|used|all}
  if (url.pathname === "/admin/api/crm/delete_gift" && request.method === "POST") {
    let body; try { body = await request.json(); } catch { return json({ error: "bad body" }, 400); }
    const step = String(body?.step || "all");
    if (!["shown", "accepted", "declined", "used", "all"].includes(step)) return json({ error: "bad step" }, 400);
    try { return json({ deleted: await rpc(env, "analytics_crm_delete_gift", { p_step: step, p_days: days, p_version: version }, range) }); }
    catch (err) { return json({ error: String(err).slice(0, 300) }, 502); }
  }

  // Rating-screen A/B report (0016_ab_rating_new_users.sql): one row per variant (A / B / "-" = outside the test)
  if (url.pathname === "/admin/api/ab_rating") {
    try { return json(await rpc(env, "analytics_ab_rating", { p_name: "rating_summary", p_days: days }, range)); }
    catch (err) { return json({ error: String(err).slice(0, 300) }, 502); }
  }

  // CRM (0006_crm_feedback.sql): ?name=users|user|feedback|feedback_summary&days=30&q=…&user=<uuid>&filter=paying&limit=200
  if (url.pathname === "/admin/api/crm") {
    const name = url.searchParams.get("name") || "";
    if (!CRM.has(name)) return json({ error: "unknown report" }, 400);
    try {
      return json(await rpc(env, "analytics_crm", {
        p_name: name, p_days: days,
        p_query: (url.searchParams.get("q") || "").slice(0, 100) || null,
        p_user: (url.searchParams.get("user") || "").slice(0, 64) || null,
        p_filter: (url.searchParams.get("filter") || "all").slice(0, 16),
        p_limit: Math.min(Math.max(parseInt(url.searchParams.get("limit") || "100", 10) || 100, 1), 500),
        p_version: version,
      }, range));
    } catch (err) {
      return json({ error: String(err).slice(0, 300) }, 502);
    }
  }

  // Legacy reports (health, rejected, anomalies, mrr, cac, …)
  if (url.pathname === "/admin/api/report") {
    const name = url.searchParams.get("name") || "";
    try {
      const rows = await rpc(env, "analytics_report", { name, days });
      return json({ name, days, rows: rows || [] });
    } catch (err) {
      return json({ error: String(err) }, 502);
    }
  }

  // Growth reports in one round trip: ?names=kpis,daily,funnel&days=30&segment=organic&country=US
  // Optional per-name segment override: names=kpis@organic,kpis@paid
  if (url.pathname === "/admin/api/growth") {
    const names = (url.searchParams.get("names") || "").split(",").map(s => s.trim()).filter(Boolean).slice(0, 32);
    const out = {};
    await Promise.all(names.map(async key => {
      const [name, seg] = key.split("@");
      if (!GROWTH.has(name) && !RELEASE.has(name) && !BILLING.has(name) && !AB.has(name)) { out[key] = { error: "unknown report" }; return; }
      try {
        const args = { p_name: name, p_days: days, p_segment: SEGMENTS.has(seg) ? seg : segment, p_country: country };
        if (AB.has(name)) args.p_test = abTest;
        out[key] = await rpc(env, RELEASE.has(name) ? "analytics_release" : BILLING.has(name) ? "analytics_billing"
                                   : AB.has(name) ? "analytics_ab" : "analytics_growth", args, range);
      } catch (err) {
        out[key] = { error: String(err).slice(0, 300) };
      }
    }));
    return json({ days, segment, country, range: range || null, reports: out });
  }

  // Ad spend import: JSON array or CSV with header
  // date,source,campaign_id,campaign_name,adset_id,adset_name,spend_usd,impressions,clicks,installs
  if (url.pathname === "/admin/api/ad_spend" && request.method === "POST") {
    const text = await request.text();
    let rows;
    try { rows = text.trim().startsWith("[") ? JSON.parse(text) : parseCSV(text); } catch { return json({ error: "bad body" }, 400); }
    try {
      const upserted = await rpc(env, "analytics_upsert_ad_spend", { rows_json: rows });
      return json({ upserted });
    } catch (err) {
      return json({ error: String(err).slice(0, 300) }, 502);
    }
  }
  return json({ error: "not found" }, 404);
}

function parseCSV(text) {
  const [head, ...lines] = text.trim().split(/\r?\n/);
  const keys = head.split(",").map(s => s.trim());
  const clean = x => (x ?? "").trim().replace(/^"(.*)"$/, "$1");
  return lines.filter(l => l.trim()).map(l => { const v = l.split(","); return Object.fromEntries(keys.map((k, i) => [k, clean(v[i])])); });
}
