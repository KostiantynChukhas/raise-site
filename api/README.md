# raise-api — analytics for Raise (same stack as X Clean)

App → `POST /events` (this Cloudflare Worker) → Supabase Postgres (`analytics` schema).
Adapty → `POST /webhooks/adapty` → payments / subscription status / refunds.
Admin UI: **https://kostiantynchukhas.github.io/raise-site/admin/** (static page, calls `/admin/api/*` here with `ADMIN_TOKEN`).
Remote config for the app: `GET /config.json` (defaults in `src/config.js`, overrides from admin → «Конфиг», stored in KV).

The SQL (`migrations/postgres/0001…0017`) is copied 1:1 from `cleanx-web`; `0018_raise.sql` adds the Raise event catalog
and switches "used the product" from scans/cleanups to practice / watch faces / sets.
`all-migrations.sql` = all files concatenated, for pasting into Supabase → SQL Editor (every file is idempotent).

## Setup
1. **Supabase**: new project `raise` → SQL Editor → paste `all-migrations.sql` → Run.
   Project Settings → API Keys: copy Project URL and the `service_role` (secret) key.
2. **Cloudflare Worker** `raise-api`: `npx wrangler deploy` in this folder (creates the KV namespace),
   or Dashboard → Workers → Create → paste a bundle (`npx esbuild src/worker.js --bundle --format=esm`), add KV binding `BUFFER`,
   cron `*/15 * * * *`, vars `APP_KEY`, `ADMIN_ORIGIN` (see `wrangler.jsonc`).
3. **Secrets** (Worker → Settings → Variables and Secrets, type Secret):
   `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `ADAPTY_WEBHOOK_SECRET`, `ADMIN_TOKEN`, optional `ALERT_WEBHOOK_URL`.
4. **Adapty** → App settings → Integrations → Webhook: URL `https://raise-api.raise-app.workers.dev/webhooks/adapty`
   (production + sandbox), Authorization header value = `ADAPTY_WEBHOOK_SECRET`.
5. **Special offer**: App Store Connect → new auto-renewable yearly subscription `com.kchukhas.raise.app.pro.yearly.offer`
   (same group as the regular yearly, lower price) → Adapty: add the product, paywall + placement `com.raise.special_offer`.

## What the app sends
| Group | Events |
|---|---|
| Onboarding | first_visit, onboarding_steps (step_name, onboarding_index), onboarding_completed, level_check_completed |
| Paywall | paywall_shown, subview (trigger), plan_choosing, purchase_started, purchase_cancelled, purchase_failed, subpurchase, paywall_cancel_click, paywall_closed, special_offer_shown, restore_tapped, paywall_load_failed |
| Gift + rating | free_clean_gift_shown / _accepted / _declined / _used (= «1 день Pro» shown / taken / declined / activated), rate_cleanup_shown / _stars / _submitted / _skipped / _feedback, review_prompt_shown (where = free_clean_gift), rating_ab_assigned, free_day_started, free_day_ended |
| In-app | app_opened, tab_bar_tapped (tab), pro_feature_locked (feature), practice_started / practice_completed (mode = daily, review, flashcards, set, speed, match), face_installed, set_created (source), achievement_unlocked |

The gift / rating events keep X Clean's names on purpose, so the CRM, «Отзывы» and the rating A/B report work without changes.
`trigger` = onboarding_flow / feature_gate / relaunch / setting / exit_offer / win_back.

Local test: `.dev.vars` with `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `ADMIN_TOKEN` → `npx wrangler dev`.
