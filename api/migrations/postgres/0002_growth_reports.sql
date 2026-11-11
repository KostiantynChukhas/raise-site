-- X Clean — growth analytics for /admin (organic vs paid, funnels, cohorts, LTV, retention, insights data).
-- Run after 0001_init.sql (Supabase → SQL Editor, or the CI workflow). Idempotent: safe to run again.
--
-- Entry point: public.analytics_growth(p_name, p_days, p_segment, p_country)
--   country: ISO code ('US', 'DE', …) or NULL/'' for all countries ('??' = unknown country)
--   segment: 'all' | 'organic' | 'paid' | 'unknown'
--     organic = AppsFlyer says Organic (App Store search/browse, word of mouth, web)
--     paid    = AppsFlyer attributed the install to a media source / campaign
--     unknown = no attribution event received from the app yet
--   Sandbox purchases are always excluded. No PII is returned.

-- ───────────────────────── Helpers ─────────────────────────

-- Older signatures (before the country filter) — dropped so calls are not ambiguous.
DROP FUNCTION IF EXISTS public.analytics_growth(TEXT, INT, TEXT);
DROP FUNCTION IF EXISTS analytics.growth_kpis(TIMESTAMPTZ, TIMESTAMPTZ, TEXT);
DROP FUNCTION IF EXISTS analytics.seg_users(TEXT);

-- One row per user with its acquisition segment. Inlined by the planner (LANGUAGE sql STABLE).
CREATE OR REPLACE FUNCTION analytics.seg_users(seg TEXT, ctry TEXT DEFAULT NULL)
RETURNS TABLE (user_id UUID, created_at TIMESTAMPTZ, country TEXT, app_version TEXT,
               segment TEXT, media_source TEXT, campaign_id TEXT, campaign_name TEXT)
LANGUAGE sql STABLE AS $$
    SELECT u.user_id, u.created_at, COALESCE(u.country, '??'), u.first_seen_app_version,
           CASE WHEN a.user_id IS NULL THEN 'unknown' WHEN a.is_organic = 'organic' THEN 'organic' ELSE 'paid' END,
           CASE WHEN a.user_id IS NULL THEN 'unknown' WHEN a.is_organic = 'organic' THEN 'organic'
                ELSE COALESCE(NULLIF(a.utm_source, ''), 'paid_unknown') END,
           COALESCE(a.campaign_id, ''), a.campaign_name
    FROM analytics.users u
    LEFT JOIN analytics.user_attribution a ON a.user_id = u.user_id
    WHERE (seg = 'all'
           OR (seg = 'organic' AND a.is_organic = 'organic')
           OR (seg = 'paid' AND a.is_organic IN ('paid_attributed', 'paid_unattributed'))
           OR (seg = 'unknown' AND a.user_id IS NULL))
      AND (ctry IS NULL OR COALESCE(u.country, '??') = ctry)
$$;

-- Real (non-sandbox) payments.
CREATE OR REPLACE VIEW analytics.v_pay AS
    SELECT p.*, (r.payment_id IS NOT NULL) AS refunded, COALESCE(r.amount_usd, 0) AS refund_usd
    FROM analytics.payments p
    LEFT JOIN analytics.refunds r ON r.payment_id = p.payment_id
    WHERE COALESCE(p.environment, '') <> 'Sandbox';

-- Monthly value of a subscription price (for MRR).
CREATE OR REPLACE FUNCTION analytics.monthly(product TEXT, amount NUMERIC) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN product ILIKE '%year%' THEN amount / 12
                WHEN product ILIKE '%week%' THEN amount * 52 / 12
                ELSE amount END
$$;

-- KPIs for one window [t0, t1) — used for the current and the previous period.
CREATE OR REPLACE FUNCTION analytics.growth_kpis(t0 TIMESTAMPTZ, t1 TIMESTAMPTZ, seg TEXT, ctry TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE sql STABLE AS $$
WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
cohort AS (SELECT * FROM su WHERE created_at >= t0 AND created_at < t1),
pay AS (SELECT p.* FROM analytics.v_pay p JOIN su USING (user_id) WHERE p.occurred_at >= t0 AND p.occurred_at < t1),
first_conv AS (   -- first trial / paid start of each cohort user, any time
    SELECT p.user_id, MIN(p.occurred_at) FILTER (WHERE p.is_trial) AS first_trial,
           MIN(p.occurred_at) FILTER (WHERE NOT p.is_trial AND p.amount_usd > 0) AS first_paid
    FROM analytics.v_pay p JOIN cohort c USING (user_id) GROUP BY 1),
trials AS (        -- trials that started in the window and had time to end (3-day trial + 1 day of retries)
    SELECT p.original_transaction_id, p.user_id FROM pay p
    WHERE p.event_type = 'trial_start' AND p.occurred_at < now() - interval '4 days'),
pw AS (SELECT DISTINCT e.user_id FROM analytics.events e JOIN su USING (user_id)
       WHERE e.event_name = 'subview' AND e.event_time >= t0 AND e.event_time < t1)
SELECT jsonb_build_object(
    'installs',            (SELECT COUNT(*) FROM cohort),
    'organic_installs',    (SELECT COUNT(*) FROM cohort WHERE segment = 'organic'),
    'paid_installs',       (SELECT COUNT(*) FROM cohort WHERE segment = 'paid'),
    'unknown_installs',    (SELECT COUNT(*) FROM cohort WHERE segment = 'unknown'),
    'paywall_viewers',     (SELECT COUNT(*) FROM pw),
    'trials',              (SELECT COUNT(*) FROM pay WHERE event_type = 'trial_start'),
    'new_paid',            (SELECT COUNT(*) FROM pay WHERE event_type IN ('initial_purchase', 'trial_converted')),
    'direct_purchases',    (SELECT COUNT(*) FROM pay WHERE event_type = 'initial_purchase'),
    'trial_conversions',   (SELECT COUNT(*) FROM pay WHERE event_type = 'trial_converted'),
    'renewals',            (SELECT COUNT(*) FROM pay WHERE event_type = 'renewal'),
    'payers',              (SELECT COUNT(DISTINCT user_id) FROM pay WHERE NOT is_trial AND amount_usd > 0),
    'revenue_usd',         (SELECT COALESCE(ROUND(SUM(amount_usd), 2), 0) FROM pay WHERE NOT is_trial),
    'proceeds_usd',        (SELECT COALESCE(ROUND(SUM(COALESCE(proceeds_usd, amount_usd * 0.7)), 2), 0) FROM pay WHERE NOT is_trial),
    'refunds',             (SELECT COUNT(*) FROM pay WHERE refunded),
    'refunds_usd',         (SELECT COALESCE(ROUND(SUM(refund_usd), 2), 0) FROM pay WHERE refunded),
    'refund_rate_pct',     (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE refunded) / NULLIF(COUNT(*), 0), 1)
                            FROM pay WHERE NOT is_trial AND amount_usd > 0),
    'install_to_paywall_pct', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (
                                   SELECT 1 FROM analytics.events e WHERE e.user_id = cohort.user_id AND e.event_name = 'subview'
                                     AND e.event_time >= cohort.created_at)) / NULLIF(COUNT(*), 0), 1) FROM cohort),
    'install_to_trial_pct',  (SELECT ROUND(100.0 * COUNT(first_trial) / NULLIF((SELECT COUNT(*) FROM cohort), 0), 2) FROM first_conv),
    'install_to_paid_pct',   (SELECT ROUND(100.0 * COUNT(first_paid) / NULLIF((SELECT COUNT(*) FROM cohort), 0), 2) FROM first_conv),
    'install_to_any_pct',    (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE first_trial IS NOT NULL OR first_paid IS NOT NULL)
                                   / NULLIF((SELECT COUNT(*) FROM cohort), 0), 2) FROM first_conv),
    'trials_matured',      (SELECT COUNT(*) FROM trials),
    'trial_to_paid_pct',   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (
                                SELECT 1 FROM analytics.v_pay x WHERE x.original_transaction_id = t.original_transaction_id
                                  AND NOT x.is_trial AND x.amount_usd > 0)) / NULLIF(COUNT(*), 0), 1) FROM trials t),
    'arpu_usd',            (SELECT ROUND(COALESCE(SUM(amount_usd), 0) / NULLIF((SELECT COUNT(*) FROM cohort), 0), 3)
                            FROM pay WHERE NOT is_trial),
    'arppu_usd',           (SELECT ROUND(SUM(amount_usd) / NULLIF(COUNT(DISTINCT user_id), 0), 2)
                            FROM pay WHERE NOT is_trial AND amount_usd > 0),
    'cohort_revenue_usd',  (SELECT COALESCE(ROUND(SUM(p.amount_usd), 2), 0) FROM analytics.v_pay p JOIN cohort USING (user_id)
                            WHERE NOT p.is_trial),
    'spend_usd',           (SELECT COALESCE(ROUND(SUM(spend_usd), 2), 0) FROM analytics.ad_spend
                            WHERE date >= t0::date AND date < t1::date AND seg IN ('all', 'paid') AND ctry IS NULL)
)
$$;

-- ───────────────────────── Reports ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_growth(p_name TEXT, p_days INT DEFAULT 30, p_segment TEXT DEFAULT 'all', p_country TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    d INT := GREATEST(1, LEAST(COALESCE(p_days, 30), 730));
    t1 TIMESTAMPTZ := now();
    t0 TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    seg TEXT := CASE WHEN p_segment IN ('organic', 'paid', 'unknown') THEN p_segment ELSE 'all' END;
    ctry TEXT := CASE WHEN upper(p_country) ~ '^([A-Z]{2}|\?\?)$' THEN upper(p_country) END;
    res JSONB;
BEGIN
    CASE p_name

    -- KPI cards with the previous period of the same length + snapshot of the subscriber base.
    WHEN 'kpis' THEN
        SELECT jsonb_build_object(
            'current', analytics.growth_kpis(t0, t1, seg, ctry),
            'previous', analytics.growth_kpis(t0 - make_interval(days => d), t0, seg, ctry),
            'snapshot', (
                WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
                last_paid AS (
                    SELECT DISTINCT ON (p.user_id) p.user_id, p.product_id, p.amount_usd
                    FROM analytics.v_pay p JOIN su USING (user_id)
                    WHERE NOT p.is_trial AND p.amount_usd > 0 ORDER BY p.user_id, p.occurred_at DESC)
                SELECT jsonb_build_object(
                    'active_paid',   COUNT(*) FILTER (WHERE s.is_active AND s.current_status <> 'trial'),
                    'active_trials', COUNT(*) FILTER (WHERE s.is_active AND s.current_status = 'trial'),
                    'auto_renew_off', COUNT(*) FILTER (WHERE s.is_active AND NOT s.will_renew),
                    'billing_issues', COUNT(*) FILTER (WHERE s.current_status IN ('billing_issue', 'in_grace_period')),
                    'mrr_usd', ROUND(COALESCE(SUM(analytics.monthly(lp.product_id, lp.amount_usd))
                                     FILTER (WHERE s.is_active AND s.current_status <> 'trial'), 0), 2))
                FROM analytics.subscription_status s JOIN su USING (user_id)
                LEFT JOIN last_paid lp ON lp.user_id = s.user_id)
        ) INTO res;

    -- One row per day: installs by segment, trials, new paid subs, revenue.
    WHEN 'daily' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        dd AS (SELECT generate_series(date_trunc('day', t0), date_trunc('day', t1), interval '1 day')::date AS day),
        inst AS (SELECT created_at::date AS day,
                        COUNT(*) FILTER (WHERE segment = 'organic') AS organic,
                        COUNT(*) FILTER (WHERE segment = 'paid') AS paid,
                        COUNT(*) FILTER (WHERE segment = 'unknown') AS unknown
                 FROM su WHERE created_at >= t0 GROUP BY 1),
        pay AS (SELECT p.occurred_at::date AS day,
                       COUNT(*) FILTER (WHERE p.event_type = 'trial_start') AS trials,
                       COUNT(*) FILTER (WHERE p.event_type IN ('initial_purchase', 'trial_converted')) AS new_paid,
                       COUNT(*) FILTER (WHERE p.event_type = 'renewal') AS renewals,
                       COALESCE(SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial), 0) AS revenue,
                       COALESCE(SUM(COALESCE(p.proceeds_usd, p.amount_usd * 0.7)) FILTER (WHERE NOT p.is_trial), 0) AS proceeds
                FROM analytics.v_pay p JOIN su USING (user_id) WHERE p.occurred_at >= t0 GROUP BY 1)
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'day', dd.day,
                   'installs', COALESCE(i.organic, 0) + COALESCE(i.paid, 0) + COALESCE(i.unknown, 0),
                   'organic', COALESCE(i.organic, 0), 'paid', COALESCE(i.paid, 0), 'unknown', COALESCE(i.unknown, 0),
                   'trials', COALESCE(p.trials, 0), 'new_paid', COALESCE(p.new_paid, 0), 'renewals', COALESCE(p.renewals, 0),
                   'revenue_usd', ROUND(COALESCE(p.revenue, 0), 2), 'proceeds_usd', ROUND(COALESCE(p.proceeds, 0), 2))
                 ORDER BY dd.day), '[]')
        INTO res
        FROM dd LEFT JOIN inst i ON i.day = dd.day LEFT JOIN pay p ON p.day = dd.day;

    -- Install cohort funnel: what share of users who installed in the period reached each step (any time later).
    WHEN 'funnel' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        ev AS (SELECT e.user_id,
                      bool_or(e.event_name = 'onboarding_completed') AS onb,
                      bool_or(e.event_name = 'subview') AS pw,
                      bool_or(e.event_name = 'plan_choosing') AS plan,
                      bool_or(e.event_name = 'purchase_started') AS started,
                      bool_or(e.event_name = 'special_offer_shown') AS offer,
                      bool_or(e.event_name IN ('scan_completed', 'cleanup_completed', 'fast_clean_completed')) AS used
               FROM analytics.events e JOIN cohort c USING (user_id)
               WHERE e.event_time >= c.created_at - interval '1 hour'
                 AND e.event_name IN ('onboarding_completed', 'subview', 'plan_choosing', 'purchase_started',
                                      'special_offer_shown', 'scan_completed', 'cleanup_completed', 'fast_clean_completed')
               GROUP BY 1),
        pay AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                       bool_or(p.event_type = 'trial_converted') AS converted, bool_or(p.event_type = 'renewal') AS renewed
                FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1),
        steps AS (
            SELECT 1 AS n, 'Установили' AS step, COUNT(*) AS users FROM cohort
            UNION ALL SELECT 2, 'Прошли онбординг', COUNT(*) FROM ev WHERE onb
            UNION ALL SELECT 3, 'Сканировали / чистили', COUNT(*) FROM ev WHERE used
            UNION ALL SELECT 4, 'Увидели пейвол', COUNT(*) FROM ev WHERE pw
            UNION ALL SELECT 5, 'Выбрали план', COUNT(*) FROM ev WHERE plan
            UNION ALL SELECT 6, 'Нажали «купить»', COUNT(*) FROM ev WHERE started
            UNION ALL SELECT 7, 'Увидели спецпредложение', COUNT(*) FROM ev WHERE offer
            UNION ALL SELECT 8, 'Начали триал', COUNT(*) FROM pay WHERE trial
            UNION ALL SELECT 9, 'Оплатили (любой план)', COUNT(*) FROM pay WHERE paid
            UNION ALL SELECT 10, 'Триал → оплата', COUNT(*) FROM pay WHERE converted
            UNION ALL SELECT 11, 'Продлили хотя бы раз', COUNT(*) FROM pay WHERE renewed)
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'step', s.step, 'users', s.users,
                   'pct_of_installs', ROUND(100.0 * s.users / NULLIF((SELECT users FROM steps WHERE n = 1), 0), 2))
                 ORDER BY s.n), '[]') INTO res FROM steps s;

    -- Acquisition: organic vs every media source / campaign, with cohort conversion, revenue, spend.
    WHEN 'sources' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        conv AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                        SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial) AS revenue
                 FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1),
        agg AS (SELECT c.segment, c.media_source AS source, c.campaign_id, MAX(c.campaign_name) AS campaign,
                       COUNT(*) AS installs, COUNT(*) FILTER (WHERE cv.trial) AS trials, COUNT(*) FILTER (WHERE cv.paid) AS payers,
                       COALESCE(SUM(cv.revenue), 0) AS revenue
                FROM cohort c LEFT JOIN conv cv USING (user_id) GROUP BY 1, 2, 3),
        spend AS (SELECT lower(source) AS source, campaign_id, SUM(spend_usd) AS spend
                  FROM analytics.ad_spend WHERE date >= t0::date AND ctry IS NULL GROUP BY 1, 2)
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'segment', a.segment, 'source', a.source, 'campaign', COALESCE(a.campaign, NULLIF(a.campaign_id, ''), '—'),
                   'installs', a.installs, 'trials', a.trials, 'payers', a.payers,
                   'install_to_trial_pct', ROUND(100.0 * a.trials / NULLIF(a.installs, 0), 2),
                   'install_to_paid_pct', ROUND(100.0 * a.payers / NULLIF(a.installs, 0), 2),
                   'revenue_usd', ROUND(a.revenue, 2), 'arpu_usd', ROUND(a.revenue / NULLIF(a.installs, 0), 3),
                   'spend_usd', ROUND(s.spend, 2), 'cpi_usd', ROUND(s.spend / NULLIF(a.installs, 0), 2),
                   'cac_usd', ROUND(s.spend / NULLIF(a.payers, 0), 2), 'roas_pct', ROUND(100.0 * a.revenue / NULLIF(s.spend, 0), 1))
                 ORDER BY a.installs DESC), '[]')
        INTO res FROM agg a LEFT JOIN spend s ON s.source = lower(a.source) AND s.campaign_id = a.campaign_id;

    -- Countries: where installs come from and where they pay (price / localization / ad-geo decisions).
    WHEN 'countries' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        cohort AS (SELECT * FROM su WHERE created_at >= t0),
        prev AS (SELECT country, COUNT(*) AS installs FROM su
                 WHERE created_at >= t0 - make_interval(days => d) AND created_at < t0 GROUP BY 1),
        conv AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                        SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial) AS revenue,
                        SUM(COALESCE(p.proceeds_usd, p.amount_usd * 0.7)) FILTER (WHERE NOT p.is_trial) AS proceeds
                 FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1),
        tr AS (SELECT c.country, COUNT(*) AS matured,
                      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.v_pay x WHERE x.original_transaction_id = p.original_transaction_id
                                       AND NOT x.is_trial AND x.amount_usd > 0)) AS converted
               FROM analytics.v_pay p JOIN cohort c USING (user_id)
               WHERE p.event_type = 'trial_start' AND p.occurred_at < now() - interval '4 days' GROUP BY 1),
        pw AS (SELECT DISTINCT e.user_id FROM analytics.events e JOIN cohort c USING (user_id) WHERE e.event_name = 'subview'),
        act AS (SELECT c.country, COUNT(*) FILTER (WHERE s.is_active AND s.current_status <> 'trial') AS active_paid
                FROM analytics.subscription_status s JOIN su c USING (user_id) GROUP BY 1)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.installs DESC), '[]') INTO res FROM (
            SELECT c.country, COUNT(*) AS installs, MAX(pv.installs) AS installs_prev,
                   COUNT(*) FILTER (WHERE c.segment = 'organic') AS organic_installs,
                   COUNT(*) FILTER (WHERE c.segment = 'paid') AS paid_installs,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE c.segment = 'organic') / COUNT(*), 0) AS organic_pct,
                   COUNT(pw.user_id) AS paywall_viewers,
                   ROUND(100.0 * COUNT(pw.user_id) / COUNT(*), 1) AS saw_paywall_pct,
                   COUNT(*) FILTER (WHERE cv.trial) AS trials,
                   COUNT(*) FILTER (WHERE cv.paid) AS payers,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cv.trial OR cv.paid) / COUNT(*), 2) AS install_to_sub_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cv.paid) / COUNT(*), 2) AS install_to_paid_pct,
                   ROUND(100.0 * MAX(tr.converted) / NULLIF(MAX(tr.matured), 0), 1) AS trial_to_paid_pct,
                   ROUND(COALESCE(SUM(cv.revenue), 0), 2) AS revenue_usd,
                   ROUND(COALESCE(SUM(cv.revenue) FILTER (WHERE c.segment = 'organic'), 0), 2) AS organic_revenue_usd,
                   ROUND(COALESCE(SUM(cv.revenue) FILTER (WHERE c.segment = 'paid'), 0), 2) AS paid_revenue_usd,
                   ROUND(COALESCE(SUM(cv.proceeds), 0), 2) AS proceeds_usd,
                   ROUND(COALESCE(SUM(cv.revenue), 0) / COUNT(*), 3) AS arpu_usd,
                   ROUND(SUM(cv.revenue) / NULLIF(COUNT(*) FILTER (WHERE cv.paid), 0), 2) AS arppu_usd,
                   COALESCE(MAX(a.active_paid), 0) AS active_paid
            FROM cohort c LEFT JOIN conv cv USING (user_id) LEFT JOIN pw USING (user_id)
            LEFT JOIN prev pv ON pv.country = c.country LEFT JOIN tr ON tr.country = c.country
            LEFT JOIN act a ON a.country = c.country
            GROUP BY 1 ORDER BY 2 DESC LIMIT 200) r;

    -- Countries for the filter drop-down (all-time installs; ignores the country filter).
    WHEN 'country_list' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.installs DESC), '[]') INTO res FROM (
            SELECT country, COUNT(*) AS installs, COUNT(*) FILTER (WHERE created_at >= t0) AS installs_period
            FROM analytics.seg_users(seg) GROUP BY 1) r;

    -- Products: trials, conversions, renewals, revenue, refunds per product id.
    WHEN 'products' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        pay AS (SELECT p.* FROM analytics.v_pay p JOIN su USING (user_id) WHERE p.occurred_at >= t0),
        trials AS (SELECT p.product_id, p.original_transaction_id,
                          EXISTS (SELECT 1 FROM analytics.v_pay x WHERE x.original_transaction_id = p.original_transaction_id
                                  AND NOT x.is_trial AND x.amount_usd > 0) AS converted
                   FROM pay p WHERE p.event_type = 'trial_start' AND p.occurred_at < now() - interval '4 days'),
        act AS (SELECT s.product_id, COUNT(*) FILTER (WHERE s.is_active AND s.current_status <> 'trial') AS active_paid,
                       COUNT(*) FILTER (WHERE s.is_active AND s.current_status = 'trial') AS active_trials
                FROM analytics.subscription_status s JOIN su USING (user_id) GROUP BY 1)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.revenue_usd DESC NULLS LAST), '[]') INTO res FROM (
            SELECT pr.product_id,
                   COUNT(*) FILTER (WHERE p.event_type = 'trial_start') AS trials,
                   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE converted) / NULLIF(COUNT(*), 0), 1)
                    FROM trials t WHERE t.product_id = pr.product_id) AS trial_to_paid_pct,
                   COUNT(*) FILTER (WHERE p.event_type = 'initial_purchase') AS direct_purchases,
                   COUNT(*) FILTER (WHERE p.event_type = 'trial_converted') AS trial_conversions,
                   COUNT(*) FILTER (WHERE p.event_type = 'renewal') AS renewals,
                   ROUND(COALESCE(SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial), 0), 2) AS revenue_usd,
                   ROUND(COALESCE(SUM(COALESCE(p.proceeds_usd, p.amount_usd * 0.7)) FILTER (WHERE NOT p.is_trial), 0), 2) AS proceeds_usd,
                   COUNT(*) FILTER (WHERE p.refunded) AS refunds,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE p.refunded) / NULLIF(COUNT(*) FILTER (WHERE NOT p.is_trial AND p.amount_usd > 0), 0), 1) AS refund_rate_pct,
                   COALESCE(MAX(a.active_paid), 0) AS active_paid, COALESCE(MAX(a.active_trials), 0) AS active_trials
            FROM (SELECT DISTINCT product_id FROM pay UNION SELECT product_id FROM act) pr
            LEFT JOIN pay p ON p.product_id = pr.product_id
            LEFT JOIN act a ON a.product_id = pr.product_id
            GROUP BY pr.product_id) r;

    -- Weekly trial cohorts: how many trials turned into paid subscriptions.
    WHEN 'trial_cohorts' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        t AS (SELECT date_trunc('week', p.occurred_at)::date AS week, p.original_transaction_id, p.occurred_at,
                     EXISTS (SELECT 1 FROM analytics.v_pay x WHERE x.original_transaction_id = p.original_transaction_id
                             AND NOT x.is_trial AND x.amount_usd > 0) AS converted,
                     EXISTS (SELECT 1 FROM analytics.subscription_status s WHERE s.user_id = p.user_id
                             AND s.original_transaction_id = p.original_transaction_id AND NOT s.will_renew) AS renew_off
              FROM analytics.v_pay p JOIN su USING (user_id) WHERE p.event_type = 'trial_start' AND p.occurred_at >= t0)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.week DESC), '[]') INTO res FROM (
            SELECT week, COUNT(*) AS trials, COUNT(*) FILTER (WHERE converted) AS converted,
                   COUNT(*) FILTER (WHERE NOT converted AND occurred_at >= now() - interval '4 days') AS pending,
                   COUNT(*) FILTER (WHERE NOT converted AND renew_off) AS cancelled_auto_renew,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE converted)
                         / NULLIF(COUNT(*) FILTER (WHERE converted OR occurred_at < now() - interval '4 days'), 0), 1) AS trial_to_paid_pct
            FROM t GROUP BY 1) r;

    -- Weekly install cohorts: revenue per install after 0 / 7 / 30 days and to date (LTV).
    WHEN 'ltv' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        rev AS (SELECT c.user_id, date_trunc('week', c.created_at)::date AS week,
                       SUM(p.amount_usd) FILTER (WHERE p.occurred_at < c.created_at + interval '1 day') AS d0,
                       SUM(p.amount_usd) FILTER (WHERE p.occurred_at < c.created_at + interval '7 days') AS d7,
                       SUM(p.amount_usd) FILTER (WHERE p.occurred_at < c.created_at + interval '30 days') AS d30,
                       SUM(p.amount_usd) AS total,
                       SUM(COALESCE(p.proceeds_usd, p.amount_usd * 0.7)) AS proceeds
                FROM cohort c LEFT JOIN analytics.v_pay p ON p.user_id = c.user_id AND NOT p.is_trial AND NOT p.refunded
                GROUP BY 1, 2)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.week DESC), '[]') INTO res FROM (
            SELECT week, COUNT(*) AS installs, COUNT(*) FILTER (WHERE total > 0) AS payers,
                   ROUND(COALESCE(SUM(d0), 0) / COUNT(*), 3) AS arpu_d0,
                   CASE WHEN week + 7 + 7 <= now()::date THEN ROUND(COALESCE(SUM(d7), 0) / COUNT(*), 3) END AS arpu_d7,
                   CASE WHEN week + 7 + 30 <= now()::date THEN ROUND(COALESCE(SUM(d30), 0) / COUNT(*), 3) END AS arpu_d30,
                   ROUND(COALESCE(SUM(total), 0) / COUNT(*), 3) AS arpu_to_date,
                   ROUND(COALESCE(SUM(total), 0), 2) AS revenue_usd, ROUND(COALESCE(SUM(proceeds), 0), 2) AS proceeds_usd
            FROM rev GROUP BY 1) r;

    -- Weekly install cohorts: share of users who came back on day 1 / 3 / 7 / 14 / 30.
    WHEN 'retention' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        act AS (SELECT DISTINCT s.user_id, floor(extract(epoch FROM s.started_at - c.created_at) / 86400)::int AS dn
                FROM analytics.sessions s JOIN cohort c USING (user_id)
                WHERE s.started_at >= c.created_at AND s.started_at < c.created_at + interval '31 days'),
        u AS (SELECT c.user_id, date_trunc('week', c.created_at)::date AS week, c.created_at,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 1) AS d1,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 3) AS d3,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 7) AS d7,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 14) AS d14,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 30) AS d30
              FROM cohort c)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.week DESC), '[]') INTO res FROM (
            SELECT week, COUNT(*) AS installs,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d1 AND created_at < now() - interval '2 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '2 days'), 0), 1) AS d1_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d3 AND created_at < now() - interval '4 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '4 days'), 0), 1) AS d3_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d7 AND created_at < now() - interval '8 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '8 days'), 0), 1) AS d7_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d14 AND created_at < now() - interval '15 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '15 days'), 0), 1) AS d14_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d30 AND created_at < now() - interval '31 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '31 days'), 0), 1) AS d30_pct
            FROM u GROUP BY 1) r;

    -- How fast users subscribe after install.
    WHEN 'time_to_purchase' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        f AS (SELECT c.user_id, MIN(p.occurred_at) - c.created_at AS dt
              FROM cohort c JOIN analytics.v_pay p USING (user_id) GROUP BY c.user_id, c.created_at),
        b AS (SELECT CASE WHEN dt < interval '5 minutes' THEN 1 WHEN dt < interval '1 hour' THEN 2
                          WHEN dt < interval '1 day' THEN 3 WHEN dt < interval '3 days' THEN 4
                          WHEN dt < interval '7 days' THEN 5 ELSE 6 END AS n FROM f)
        SELECT COALESCE(jsonb_agg(jsonb_build_object('when', l.label, 'subscribers', COALESCE(x.cnt, 0),
                   'share_pct', ROUND(100.0 * COALESCE(x.cnt, 0) / NULLIF((SELECT COUNT(*) FROM b), 0), 1)) ORDER BY l.n), '[]')
        INTO res
        FROM (VALUES (1, 'первые 5 мин (пейвол онбординга)'), (2, '5–60 мин'), (3, '1–24 ч'), (4, '2–3 день'),
                     (5, '4–7 день'), (6, 'позже недели')) l(n, label)
        LEFT JOIN (SELECT n, COUNT(*) AS cnt FROM b GROUP BY 1) x ON x.n = l.n;

    -- Paywall by trigger for the segment: views → buy taps → purchases, plus the plan mix.
    WHEN 'paywall' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        e AS (SELECT e.* FROM analytics.events e JOIN su USING (user_id)
              WHERE e.event_time >= t0 AND e.event_name IN ('subview', 'plan_choosing', 'purchase_started', 'subpurchase',
                                                            'purchase_cancelled', 'purchase_failed', 'paywall_cancel_click'))
        SELECT COALESCE(jsonb_agg(r ORDER BY r.viewers DESC), '[]') INTO res FROM (
            SELECT COALESCE(properties->>'trigger', 'unknown') AS trigger,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subview') AS viewers,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_started') AS tapped_buy,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subpurchase') AS purchased,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_cancelled') AS cancelled_in_apple_sheet,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_failed') AS failed,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'paywall_cancel_click') AS closed,
                   ROUND(100.0 * COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subpurchase')
                         / NULLIF(COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subview'), 0), 2) AS cr_pct,
                   ROUND(100.0 * COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subpurchase')
                         / NULLIF(COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_started'), 0), 1) AS tap_to_buy_pct,
                   COUNT(*) FILTER (WHERE event_name = 'subpurchase' AND properties->>'product_id' ILIKE '%week%') AS bought_weekly,
                   COUNT(*) FILTER (WHERE event_name = 'subpurchase' AND properties->>'product_id' ILIKE '%offer%') AS bought_offer,
                   COUNT(*) FILTER (WHERE event_name = 'subpurchase' AND properties->>'product_id' ILIKE '%year%'
                                    AND properties->>'product_id' NOT ILIKE '%offer%') AS bought_yearly
            FROM e GROUP BY 1) r;

    -- Which locked features make people buy (purchase within 24 h after hitting the lock).
    WHEN 'features' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        lk AS (SELECT e.user_id, e.properties->>'feature' AS feature, MIN(e.event_time) AS at
               FROM analytics.events e JOIN su USING (user_id)
               WHERE e.event_name = 'pro_feature_locked' AND e.event_time >= t0 GROUP BY 1, 2)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users_locked DESC), '[]') INTO res FROM (
            SELECT COALESCE(feature, 'other') AS feature, COUNT(*) AS users_locked,
                   COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.events s WHERE s.user_id = lk.user_id
                                    AND s.event_name = 'subpurchase' AND s.event_time BETWEEN lk.at AND lk.at + interval '24 hours')) AS bought_24h,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.events s WHERE s.user_id = lk.user_id
                                    AND s.event_name = 'subpurchase' AND s.event_time BETWEEN lk.at AND lk.at + interval '24 hours'))
                         / COUNT(*), 2) AS cr_pct
            FROM lk GROUP BY 1) r;

    -- Releases: does the new version convert better?
    WHEN 'versions' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        conv AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                        SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial) AS revenue
                 FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1),
        pw AS (SELECT DISTINCT e.user_id FROM analytics.events e JOIN cohort USING (user_id) WHERE e.event_name = 'subview')
        SELECT COALESCE(jsonb_agg(r ORDER BY r.first_install DESC), '[]') INTO res FROM (
            SELECT c.app_version, MIN(c.created_at)::date AS first_install, COUNT(*) AS installs,
                   ROUND(100.0 * COUNT(pw.user_id) / COUNT(*), 1) AS saw_paywall_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cv.trial) / COUNT(*), 2) AS trial_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cv.paid) / COUNT(*), 2) AS paid_pct,
                   ROUND(COALESCE(SUM(cv.revenue), 0) / COUNT(*), 3) AS arpu_usd
            FROM cohort c LEFT JOIN conv cv USING (user_id) LEFT JOIN pw USING (user_id) GROUP BY 1) r;

    -- Churn: why and when subscribers leave.
    WHEN 'churn' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry))
        SELECT jsonb_build_object(
            'status', (SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') FROM (
                SELECT s.current_status AS status, s.product_id, COUNT(*) AS users
                FROM analytics.subscription_status s JOIN su USING (user_id) GROUP BY 1, 2) r),
            'cancel_reasons', (SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') FROM (
                SELECT COALESCE(s.cancellation_reason, 'unknown') AS reason, COUNT(*) AS users
                FROM analytics.subscription_status s JOIN su USING (user_id)
                WHERE s.cancel_date >= t0 GROUP BY 1) r),
            'cancel_after_days', (SELECT COALESCE(jsonb_agg(r ORDER BY r.n), '[]') FROM (
                SELECT CASE WHEN dd < 1 THEN 1 WHEN dd < 3 THEN 2 WHEN dd < 7 THEN 3 WHEN dd < 30 THEN 4 ELSE 5 END AS n,
                       CASE WHEN dd < 1 THEN 'в тот же день' WHEN dd < 3 THEN '1–2 день' WHEN dd < 7 THEN '3–6 день'
                            WHEN dd < 30 THEN '2–4 неделя' ELSE 'позже месяца' END AS after, COUNT(*) AS users
                FROM (SELECT extract(epoch FROM s.cancel_date - MIN(p.occurred_at)) / 86400 AS dd
                      FROM analytics.subscription_status s JOIN su USING (user_id)
                      JOIN analytics.v_pay p ON p.original_transaction_id = s.original_transaction_id
                      WHERE s.cancel_date >= t0 GROUP BY s.user_id, s.cancel_date) x
                GROUP BY 1, 2) r)
        ) INTO res;

    -- Onboarding drop-off for the segment.
    WHEN 'onboarding' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.idx), '[]') INTO res FROM (
            SELECT (e.properties->>'onboarding_index')::int AS idx, MAX(e.properties->>'step_name') AS step,
                   COUNT(DISTINCT e.user_id) AS users,
                   ROUND(100.0 * COUNT(DISTINCT e.user_id) / NULLIF((SELECT COUNT(*) FROM cohort), 0), 1) AS pct_of_installs
            FROM analytics.events e JOIN cohort USING (user_id)
            WHERE e.event_name = 'onboarding_steps' AND (e.properties->>'onboarding_index') ~ '^[0-9]+$'
            GROUP BY 1) r;

    -- What users do in the app (engagement drivers).
    WHEN 'engagement' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        payers AS (SELECT DISTINCT p.user_id FROM analytics.v_pay p JOIN su USING (user_id))
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT CASE WHEN e.event_name IN ('scan_completed', 'cleanup_completed') THEN e.event_name || ':' || COALESCE(e.properties->>'scan_type', '?')
                        WHEN e.event_name = 'tab_bar_tapped' THEN 'tab:' || COALESCE(e.properties->>'tab', '?')
                        ELSE e.event_name END AS action,
                   COUNT(*) AS events, COUNT(DISTINCT e.user_id) AS users,
                   COUNT(DISTINCT e.user_id) FILTER (WHERE py.user_id IS NOT NULL) AS of_them_subscribers,
                   ROUND(100.0 * COUNT(DISTINCT e.user_id) FILTER (WHERE py.user_id IS NOT NULL) / NULLIF(COUNT(DISTINCT e.user_id), 0), 1) AS subscriber_pct
            FROM analytics.events e JOIN su USING (user_id) LEFT JOIN payers py ON py.user_id = e.user_id
            WHERE e.event_time >= t0 AND e.event_name IN
                ('scan_completed', 'cleanup_completed', 'fast_clean_completed', 'charging_animation_selected',
                 'charging_animation_shown', 'widget_selected', 'widget_installed', 'tab_bar_tapped', 'review_prompt_shown',
                 'restore_tapped', 'support_opened', 'permission_result')
            GROUP BY 1 ORDER BY 3 DESC LIMIT 60) r;

    -- Hour of day (UTC) and weekday when people subscribe — for push / ad scheduling.
    WHEN 'timing' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry))
        SELECT COALESCE(jsonb_agg(r ORDER BY r.hour_utc), '[]') INTO res FROM (
            SELECT extract(hour FROM p.occurred_at)::int AS hour_utc,
                   COUNT(*) FILTER (WHERE p.event_type = 'trial_start') AS trials,
                   COUNT(*) FILTER (WHERE p.event_type = 'initial_purchase') AS purchases
            FROM analytics.v_pay p JOIN su USING (user_id)
            WHERE p.occurred_at >= t0 AND p.event_type IN ('trial_start', 'initial_purchase') GROUP BY 1) r;

    ELSE
        RAISE EXCEPTION 'unknown growth report %', p_name USING ERRCODE = '22023';
    END CASE;
    RETURN res;
END $$;

-- Only the Worker (service_role key) may call it — same rule as the other analytics_* functions.
REVOKE ALL ON FUNCTION public.analytics_growth(TEXT, INT, TEXT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_growth(TEXT, INT, TEXT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_growth(TEXT, INT, TEXT, TEXT) TO service_role;
    END IF;
END $$;

-- Speeds up "first payment per user" and per-transaction lookups used above.
CREATE INDEX IF NOT EXISTS idx_payments_user_occurred ON analytics.payments(user_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_sessions_user_started ON analytics.sessions(user_id, started_at);

-- Tell Supabase's API (PostgREST) to pick up the new function right away.
NOTIFY pgrst, 'reload schema';
