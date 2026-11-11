// Remote app config: GET /config.json = DEFAULTS below + overrides saved from the admin (KV).
// The app re-reads it on launch / return to foreground (at most every 5 min), so admin changes apply within minutes.
// ⚠️ Public file — never put secrets here.
import { json } from "./util.js";

const KV_KEY = "config:overrides";
const BASE = "https://raise-api.raise-app.workers.dev";
const SITE = "https://kostiantynchukhas.github.io/raise-site";

export const DEFAULTS = {
  analytics_enabled: "true",
  analytics_url: BASE + "/events",
  special_offer_enabled: "true",
  special_offer_placement: "com.raise.special_offer",
  special_offer_countdown_min: "15",
  special_offer_close_delay_sec: "3",
  free_day_gift_enabled: "true",
  free_day_gift_rating_enabled: "true",
  free_day_hours: "24",
  ab_rating_test_name: "rating_screen_v1",
  ab_rating_split_b: "0",
  ab_rating_winner: "",
  ab_rating_b_skip: "hidden",
  paywall_placement: "com.raise.pro.placement",
  support_email: "kostiantynchukhas@gmail.com",
  privacy_url: SITE + "/privacy.html",
  terms_url: SITE + "/terms.html",
  support_url: SITE + "/support.html",
};

// What the admin can change. type: bool | string | int (min/max) | enum (values). Anything else is rejected.
export const CONFIG_SCHEMA = {
  // ── A/B test of the rating screen (RatingABTest.swift): A = «Как вам Raise?», B = «Оцените — и день Pro ваш» + кнопка
  ab_rating_test_name: { type: "string", label: "A/B оценка: имя теста (смена имени = новое назначение вариантов)", group: "ab" },
  ab_rating_split_b:   { type: "int", min: 0, max: 100, label: "A/B оценка: доля пользователей в варианте B, % (0 = тест выключен, все видят A)", group: "ab" },
  ab_rating_winner:    { type: "enum", values: ["", "A", "B"], label: "A/B оценка: победитель / kill switch — всем принудительно A или B (пусто = тест идёт)", group: "ab" },
  ab_rating_b_skip:    { type: "enum", values: ["hidden", "delayed"], label: "A/B оценка, вариант B: «Не сейчас» — hidden (нет кнопки) или delayed (появляется через 4 с)", group: "ab" },
  // ── Paywall / offers
  special_offer_enabled: { type: "bool", label: "Спешл оффер: один раз, когда закрыли пейвол без покупки (скидка на годовую + таймер)" },
  special_offer_placement: { type: "string", label: "Спешл оффер: Adapty placement" },
  special_offer_countdown_min: { type: "int", min: 1, max: 1440, label: "Спешл оффер: таймер, минут" },
  special_offer_close_delay_sec: { type: "int", min: 0, max: 15, label: "Спешл оффер: через сколько секунд появляется крестик" },
  free_day_gift_enabled: { type: "bool", label: "Подарок «Ты счастливчик — 1 день Pro бесплатно» тем, кто закрыл пейвол и спешл оффер (один раз за установку)" },
  free_day_gift_rating_enabled: { type: "bool", label: "Подарок → экран «Оцените Raise» перед активацией дня (4–5★ → окно App Store, 1–3★ → отзыв в админку). Выкл. = сразу активировать день" },
  free_day_hours: { type: "int", min: 1, max: 168, label: "Сколько часов Pro дарим (24 = 1 день)" },
  paywall_placement: { type: "string", label: "Adapty placement основного пейвола" },
  analytics_enabled: { type: "bool", label: "Отправлять аналитику из приложения" },
  support_email: { type: "string", label: "E-mail поддержки" },
  privacy_url: { type: "string", label: "Ссылка на Privacy Policy" },
  terms_url: { type: "string", label: "Ссылка на Terms of Use" },
  support_url: { type: "string", label: "Ссылка на страницу поддержки" },
};

async function overrides(env) {
  if (!env.BUFFER) return {};
  try { return JSON.parse((await env.BUFFER.get(KV_KEY)) || "{}"); } catch { return {}; }
}

/** Public: merged config for the app. */
export async function serveConfig(request, env) {
  const merged = { ...DEFAULTS, ...(await overrides(env)) };
  return new Response(JSON.stringify(merged, null, 2), {
    headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=30", "Access-Control-Allow-Origin": "*" },
  });
}

/** Admin: GET → {schema, defaults, overrides, merged}; POST {key: value|null} → save (null = back to default). */
export async function adminConfig(request, env) {
  if (!env.BUFFER) return json({ error: "KV binding BUFFER is missing" }, 500);
  const def = DEFAULTS;
  let over = await overrides(env);
  if (request.method === "POST") {
    let body;
    try { body = await request.json(); } catch { return json({ error: "bad json" }, 400); }
    for (const [key, value] of Object.entries(body || {})) {
      const spec = CONFIG_SCHEMA[key];
      if (!spec) return json({ error: `unknown key ${key}` }, 400);
      if (value === null) { delete over[key]; continue; }
      if (spec.type === "bool") over[key] = (value === true || value === "true") ? "true" : "false";
      else if (spec.type === "int") {
        const n = parseInt(String(value).trim(), 10);
        if (!Number.isFinite(n) || n < spec.min || n > spec.max) return json({ error: `${key}: integer ${spec.min}–${spec.max} expected` }, 400);
        over[key] = String(n);
      } else if (spec.type === "enum") {
        const v = String(value).trim();
        if (!spec.values.includes(v)) return json({ error: `${key}: one of ${spec.values.map(x => x || "(empty)").join(", ")}` }, 400);
        over[key] = v;
      }
      else over[key] = String(value).trim().slice(0, 500);
    }
    await env.BUFFER.put(KV_KEY, JSON.stringify(over));
  }
  return json({ schema: CONFIG_SCHEMA, defaults: def, overrides: over, merged: { ...def, ...over } });
}
