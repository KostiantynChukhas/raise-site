-- X Clean 2.1 — new events + "Релизы" reports in /admin (trial push, re-engagement pushes, Security Check per app version).
-- Run after 0002_growth_reports.sql (Supabase → SQL Editor → paste → Run). Idempotent: safe to run again.
--
-- Entry point: public.analytics_release(p_name, p_days, p_segment, p_country)
--   release_versions — per app version: active users, trials, trial push sent/opened, same-day trial cancels,
--                      trial→paid, Security Check usage and average score, re-engagement push opens
--   trial_push       — trials split by "opened the trial push / push sent, not opened / no push": same-day cancels, trial→paid
--   push_opens       — every push kind (trial, d1, d3, d7, d14) per version: opens and purchases within 24 h
--   security_issues  — which Security Check findings users actually have
--   security_actions — what users tap on the findings, and purchases within 24 h

-- ───────────────────────── Event catalog ─────────────────────────

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('push_scheduled',   '{kind}',   'Local push planned (kind = trial; status = scheduled / denied / disabled, delay_min, with_numbers)'),
  ('push_opened',      '{kind}',   'Local push tapped (kind = trial / d1 / d3 / d7 / d14)'),
  ('security_opened',  '{}',       'Security Check screen opened (badge = issues on the button or "new")'),
  ('security_action',  '{action}', 'Tap on a Security Check finding (action, check, items)')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

-- scan_started / scan_completed / cleanup_completed with scan_type = 'security'
UPDATE analytics.property_enums
SET allowed = (SELECT ARRAY(SELECT DISTINCT unnest(allowed || ARRAY['security'])))
WHERE property = 'scan_type' AND NOT ('security' = ANY(allowed));

-- ───────────────────────── Reports ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_release(p_name TEXT, p_days INT DEFAULT 30, p_segment TEXT DEFAULT 'all', p_country TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    t0 TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    seg TEXT := CASE WHEN p_segment IN ('organic', 'paid', 'unknown') THEN p_segment ELSE 'all' END;
    ctry TEXT := CASE WHEN upper(p_country) ~ '^([A-Z]{2}|\?\?)$' THEN upper(p_country) END;
    res JSONB;
BEGIN
    CASE p_name

    -- One row per app version: did the release change behaviour?
    WHEN 'release_versions' THEN
        WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
        ev AS (SELECT e.user_id, e.event_name, e.app_version, e.properties, e.event_time
               FROM analytics.events e JOIN su USING (user_id)
               WHERE e.event_time >= t0
                 AND e.event_name IN ('app_opened', 'push_scheduled', 'push_opened', 'security_opened', 'scan_completed')),
        tr AS (SELECT * FROM analytics.release_trials(t0, seg, ctry)),
        v AS (
            SELECT app_version,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'app_opened') AS active_users,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'security_opened') AS security_users,
                   COUNT(*) FILTER (WHERE event_name = 'scan_completed' AND properties->>'scan_type' = 'security') AS security_scans,
                   ROUND(AVG((properties->>'score')::numeric) FILTER (WHERE event_name = 'scan_completed'
                         AND properties->>'scan_type' = 'security' AND properties->>'score' ~ '^[0-9]+$'), 0) AS avg_security_score,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'push_opened' AND properties->>'kind' LIKE 'd%') AS reengage_push_users
            FROM ev GROUP BY 1),
        t AS (
            SELECT app_version, COUNT(*) AS trials,
                   COUNT(*) FILTER (WHERE push_status = 'scheduled') AS trial_push_sent,
                   COUNT(*) FILTER (WHERE push_opened) AS trial_push_opened,
                   COUNT(*) FILTER (WHERE cancelled_same_day) AS cancelled_same_day,
                   COUNT(*) FILTER (WHERE matured) AS matured, COUNT(*) FILTER (WHERE matured AND converted) AS converted
            FROM tr GROUP BY 1)
        SELECT COALESCE(jsonb_agg(r), '[]') INTO res FROM (
            SELECT COALESCE(v.app_version, t.app_version) AS app_version, COALESCE(v.active_users, 0) AS active_users,
                   COALESCE(t.trials, 0) AS trials,
                   ROUND(100.0 * t.trial_push_sent / NULLIF(t.trials, 0), 1) AS trial_push_sent_pct,
                   ROUND(100.0 * t.trial_push_opened / NULLIF(t.trial_push_sent, 0), 1) AS trial_push_open_pct,
                   ROUND(100.0 * t.cancelled_same_day / NULLIF(t.trials, 0), 1) AS cancel_same_day_pct,
                   ROUND(100.0 * t.converted / NULLIF(t.matured, 0), 1) AS trial_to_paid_pct,
                   COALESCE(v.security_users, 0) AS security_users,
                   ROUND(100.0 * v.security_users / NULLIF(v.active_users, 0), 1) AS security_pct,
                   COALESCE(v.security_scans, 0) AS security_scans, v.avg_security_score,
                   COALESCE(v.reengage_push_users, 0) AS reengage_push_users
            FROM v FULL JOIN t USING (app_version)) r;

    -- Does the trial push reduce same-day cancels?
    WHEN 'trial_push' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.app_version DESC, r.n), '[]') INTO res FROM (
            SELECT app_version,
                   CASE WHEN push_opened THEN 1 WHEN push_status = 'scheduled' THEN 2 ELSE 3 END AS n,
                   CASE WHEN push_opened THEN 'Открыли пуш'
                        WHEN push_status = 'scheduled' THEN 'Пуш отправлен, не открыли'
                        WHEN push_status = 'denied' THEN 'Без пуша: уведомления запрещены'
                        WHEN push_status = 'disabled' THEN 'Без пуша: выключен в админке'
                        ELSE 'Без пуша: старая версия' END AS push_group,
                   COUNT(*) AS trials,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cancelled_same_day) / COUNT(*), 1) AS cancel_same_day_pct,
                   COUNT(*) FILTER (WHERE matured) AS matured,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE matured AND converted) / NULLIF(COUNT(*) FILTER (WHERE matured), 0), 1) AS trial_to_paid_pct
            FROM analytics.release_trials(t0, seg, ctry) GROUP BY 1, 2, 3) r;

    -- Every push kind: opens and purchases within 24 h after the tap.
    WHEN 'push_opens' THEN
        WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
        o AS (SELECT e.user_id, e.app_version, e.event_time, COALESCE(e.properties->>'kind', 'unknown') AS kind
              FROM analytics.events e JOIN su USING (user_id)
              WHERE e.event_name = 'push_opened' AND e.event_time >= t0)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.app_version DESC, r.opens DESC), '[]') INTO res FROM (
            SELECT o.kind AS push_kind, o.app_version, COUNT(*) AS opens, COUNT(DISTINCT o.user_id) AS users,
                   COUNT(DISTINCT o.user_id) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.events s WHERE s.user_id = o.user_id
                         AND s.event_name = 'subpurchase' AND s.event_time BETWEEN o.event_time AND o.event_time + interval '24 hours')) AS bought_24h
            FROM o GROUP BY 1, 2) r;

    -- Which findings people actually have (latest security scan of each user in the period).
    WHEN 'security_issues' THEN
        WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
        last_scan AS (
            SELECT DISTINCT ON (e.user_id) e.user_id, COALESCE(e.properties->>'issues', '') AS issues
            FROM analytics.events e JOIN su USING (user_id)
            WHERE e.event_name = 'scan_completed' AND e.properties->>'scan_type' = 'security' AND e.event_time >= t0
            ORDER BY e.user_id, e.event_time DESC),
        total AS (SELECT COUNT(*) AS n FROM last_scan)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT x.check_name, COUNT(*) AS users, ROUND(100.0 * COUNT(*) / NULLIF((SELECT n FROM total), 0), 1) AS share_pct
            FROM last_scan l CROSS JOIN LATERAL unnest(string_to_array(NULLIF(l.issues, ''), ',')) AS x(check_name)
            GROUP BY 1) r;

    -- What people tap on the findings, and whether they buy afterwards.
    WHEN 'security_actions' THEN
        WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
        a AS (SELECT e.user_id, e.event_time, e.properties->>'action' AS action, COALESCE(e.properties->>'check', '') AS check_name
              FROM analytics.events e JOIN su USING (user_id)
              WHERE e.event_name = 'security_action' AND e.event_time >= t0)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT a.action, a.check_name, COUNT(*) AS events, COUNT(DISTINCT a.user_id) AS users,
                   COUNT(DISTINCT a.user_id) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.events s WHERE s.user_id = a.user_id
                         AND s.event_name = 'subpurchase' AND s.event_time BETWEEN a.event_time AND a.event_time + interval '24 hours')) AS bought_24h
            FROM a GROUP BY 1, 2) r;

    ELSE
        RAISE EXCEPTION 'unknown release report %', p_name USING ERRCODE = '22023';
    END CASE;
    RETURN res;
END $$;

-- Trials started since t0 with the app version they started in, the trial push status and the outcome.
CREATE OR REPLACE FUNCTION analytics.release_trials(t0 TIMESTAMPTZ, seg TEXT, ctry TEXT DEFAULT NULL)
RETURNS TABLE (user_id UUID, app_version TEXT, started_at TIMESTAMPTZ, push_status TEXT, push_opened BOOLEAN,
               cancelled_same_day BOOLEAN, matured BOOLEAN, converted BOOLEAN)
LANGUAGE sql STABLE SET search_path = analytics, public AS $$
    SELECT p.user_id,
           COALESCE((SELECT e.app_version FROM analytics.events e
                     WHERE e.user_id = p.user_id AND e.event_time BETWEEN p.occurred_at - interval '1 day' AND p.occurred_at + interval '1 hour'
                     ORDER BY abs(extract(epoch FROM e.event_time - p.occurred_at)) LIMIT 1), '?') AS app_version,
           p.occurred_at,
           (SELECT e.properties->>'status' FROM analytics.events e
            WHERE e.user_id = p.user_id AND e.event_name = 'push_scheduled' AND e.properties->>'kind' = 'trial'
              AND e.event_time BETWEEN p.occurred_at - interval '1 hour' AND p.occurred_at + interval '1 hour'
            ORDER BY e.event_time DESC LIMIT 1) AS push_status,
           EXISTS (SELECT 1 FROM analytics.events e
                   WHERE e.user_id = p.user_id AND e.event_name = 'push_opened' AND e.properties->>'kind' = 'trial'
                     AND e.event_time BETWEEN p.occurred_at AND p.occurred_at + interval '1 day') AS push_opened,
           EXISTS (SELECT 1 FROM analytics.subscription_status s
                   WHERE s.user_id = p.user_id AND s.original_transaction_id = p.original_transaction_id
                     AND s.cancel_date IS NOT NULL AND s.cancel_date < p.occurred_at + interval '1 day') AS cancelled_same_day,
           p.occurred_at < now() - interval '4 days' AS matured,
           EXISTS (SELECT 1 FROM analytics.v_pay c
                   WHERE c.original_transaction_id = p.original_transaction_id AND c.event_type = 'trial_converted') AS converted
    FROM analytics.v_pay p JOIN analytics.seg_users(seg, ctry) su ON su.user_id = p.user_id
    WHERE p.event_type = 'trial_start' AND p.occurred_at >= t0
$$;

-- Only the Worker (service_role key) may call it.
REVOKE ALL ON FUNCTION public.analytics_release(TEXT, INT, TEXT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_release(TEXT, INT, TEXT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_release(TEXT, INT, TEXT, TEXT) TO service_role;
    END IF;
END $$;

NOTIFY pgrst, 'reload schema';
