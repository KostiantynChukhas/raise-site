-- X Clean — payment problems (Grace Period / billing retry) and win-back for /admin → «Деньги».
-- Run after 0003_security_check.sql (Supabase → SQL Editor → paste → Run). Idempotent: safe to run again.
--
-- Entry point: public.analytics_billing(p_name, p_days, p_segment, p_country)
--   billing_winback → { billing: funnel, billing_now: statuses, winback: funnel }

-- ───────────────────────── Event catalog ─────────────────────────

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('billing_issue_shown', '{state}', 'Banner "payment failed — update payment method" shown (state = grace / retry, where)'),
  ('billing_fix_tapped',  '{state}', '"Update payment" tapped → Apple billing page (state = grace / retry, where)')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

-- ───────────────────────── Report ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_billing(p_name TEXT, p_days INT DEFAULT 30, p_segment TEXT DEFAULT 'all', p_country TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    t0 TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    seg TEXT := CASE WHEN p_segment IN ('organic', 'paid', 'unknown') THEN p_segment ELSE 'all' END;
    ctry TEXT := CASE WHEN upper(p_country) ~ '^([A-Z]{2}|\?\?)$' THEN upper(p_country) END;
    res JSONB;
BEGIN
    IF p_name <> 'billing_winback' THEN
        RAISE EXCEPTION 'unknown billing report %', p_name USING ERRCODE = '22023';
    END IF;

    WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
    -- Apple could not charge (Adapty billing_issue_detected → payments.event_type = billing_retry)
    issue AS (SELECT p.user_id, MIN(p.occurred_at) AS at FROM analytics.v_pay p JOIN su USING (user_id)
              WHERE p.event_type = 'billing_retry' AND p.occurred_at >= t0 GROUP BY 1),
    recovered AS (SELECT DISTINCT i.user_id FROM issue i JOIN analytics.v_pay p ON p.user_id = i.user_id
                  WHERE p.event_type IN ('renewal', 'trial_converted', 'initial_purchase') AND p.occurred_at > i.at),
    ev AS (SELECT e.user_id, e.event_name, e.properties FROM analytics.events e JOIN su USING (user_id)
           WHERE e.event_time >= t0 AND e.event_name IN ('billing_issue_shown', 'billing_fix_tapped', 'subview', 'subpurchase', 'push_opened')),
    cancelled AS (SELECT s.user_id FROM analytics.subscription_status s JOIN su USING (user_id)
                  WHERE s.cancel_date >= t0 AND COALESCE(s.cancellation_reason, '') <> 'billing_error'),
    n AS (SELECT
        (SELECT COUNT(*) FROM issue) AS issues,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'billing_issue_shown') AS banner,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'billing_fix_tapped') AS fix,
        (SELECT COUNT(*) FROM recovered) AS recovered,
        (SELECT COUNT(*) FROM cancelled) AS cancelled,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'subview' AND properties->>'trigger' = 'win_back') AS wb_seen,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'push_opened' AND properties->>'kind' = 'winback') AS wb_push,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'subpurchase' AND properties->>'trigger' = 'win_back') AS wb_bought)
    SELECT jsonb_build_object(
        'billing', jsonb_build_array(
            jsonb_build_object('step', 'Оплата не прошла (Apple не смогла списать)', 'users', n.issues, 'pct', CASE WHEN n.issues > 0 THEN 100 END),
            jsonb_build_object('step', 'Увидели баннер «Обновите оплату»', 'users', n.banner, 'pct', ROUND(100.0 * n.banner / NULLIF(n.issues, 0), 1)),
            jsonb_build_object('step', 'Нажали «Обновить оплату»', 'users', n.fix, 'pct', ROUND(100.0 * n.fix / NULLIF(n.issues, 0), 1)),
            jsonb_build_object('step', 'Оплата прошла после ошибки', 'users', n.recovered, 'pct', ROUND(100.0 * n.recovered / NULLIF(n.issues, 0), 1))),
        'billing_now', (SELECT COALESCE(jsonb_agg(r ORDER BY r.n), '[]') FROM (
            SELECT 1 AS n, 'Сейчас в Grace Period (PRO работает, оплата ещё не прошла)' AS status,
                   COUNT(*) FILTER (WHERE s.current_status = 'in_grace_period') AS users FROM analytics.subscription_status s JOIN su USING (user_id)
            UNION ALL
            SELECT 2, 'Сейчас в billing retry (PRO выключен, Apple повторяет списание)',
                   COUNT(*) FILTER (WHERE s.current_status = 'billing_issue') FROM analytics.subscription_status s JOIN su USING (user_id)
            UNION ALL
            SELECT 3, 'Потеряны из-за ошибки оплаты за период',
                   COUNT(*) FILTER (WHERE s.cancellation_reason = 'billing_error' AND s.cancel_date >= t0)
            FROM analytics.subscription_status s JOIN su USING (user_id)) r),
        'winback', jsonb_build_array(
            jsonb_build_object('step', 'Сами отключили автопродление', 'users', n.cancelled, 'pct', CASE WHEN n.cancelled > 0 THEN 100 END),
            jsonb_build_object('step', 'Увидели win-back', 'users', n.wb_seen, 'pct', ROUND(100.0 * n.wb_seen / NULLIF(n.cancelled, 0), 1)),
            jsonb_build_object('step', 'Открыли win-back пуш', 'users', n.wb_push, 'pct', ROUND(100.0 * n.wb_push / NULLIF(n.cancelled, 0), 1)),
            jsonb_build_object('step', 'Купили на win-back (% от увидевших)', 'users', n.wb_bought, 'pct', ROUND(100.0 * n.wb_bought / NULLIF(n.wb_seen, 0), 1)))
    ) INTO res FROM n;
    RETURN res;
END $$;

REVOKE ALL ON FUNCTION public.analytics_billing(TEXT, INT, TEXT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_billing(TEXT, INT, TEXT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_billing(TEXT, INT, TEXT, TEXT) TO service_role;
    END IF;
END $$;

NOTIFY pgrst, 'reload schema';
