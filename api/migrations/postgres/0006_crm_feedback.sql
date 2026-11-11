-- X Clean — CRM in /admin: user list + user card, in-app feedback (rating before the free gift cleanup).
-- Run after 0005_ab_paywall.sql. Idempotent: safe to run again (CI runs every file on each push).
--
-- Entry point: public.analytics_crm(p_name, p_days, p_query, p_user, p_filter, p_limit)
--   feedback_summary → {shown, rated, avg_stars, stars:[{stars,users}], high, low, skipped, with_text, system_prompts, gift:{…}}
--   feedback         → newest first: [{event_time, user_id, stars, text, country, app_version, status}]
--   users            → [{user_id, created_at, last_seen_at, country, app_version, source, campaign, organic, status, product_id,
--                        will_renew, revenue_usd, sessions, events, stars, feedback}]
--                       p_query = beginning of user_id / Adapty profile id; p_filter = all|paying|trial|churned|free|feedback
--   user             → {profile, device, attribution, subscription, payments[], feedback[], events[]}  (p_user = user_id)
-- Raw payloads, IP, IDFV and push tokens are never returned.

-- ───────────────────────── Event catalog (app v2.3–2.4) ─────────────────────────

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('free_clean_gift_shown',    '{}', 'Free Fast Clean gift offered (paywall + special offer closed without buying)'),
  ('free_clean_gift_accepted', '{}', 'Free Fast Clean gift accepted'),
  ('free_clean_gift_declined', '{}', 'Free Fast Clean gift declined'),
  ('free_clean_gift_used',     '{}', 'Free Fast Clean done (items, bytes)'),
  ('rate_cleanup_shown',       '{}', 'In-app "How do you like X Clean?" screen shown'),
  ('rate_cleanup_stars',       '{}', 'Stars tapped on the in-app rating screen (stars = 1..5)'),
  ('rate_cleanup_skipped',     '{}', 'In-app rating skipped (stars when skipped on the feedback form)'),
  ('rate_cleanup_feedback',    '{}', 'Written feedback after 1–3 stars (stars, text ≤ 1000 chars)'),
  ('mail_opened',              '{}', 'Mail section opened'),
  ('mail_accounts_opened',     '{}', 'Mail accounts screen opened'),
  ('mail_coming_soon_shown',   '{}', 'Mail section switched off in /admin → "Coming soon" shown'),
  ('mail_sign_in_started',     '{}', 'Mail sign-in started (provider)'),
  ('mail_sign_in_completed',   '{}', 'Mail sign-in completed (provider)'),
  ('mail_sign_in_cancelled',   '{}', 'Mail sign-in cancelled (provider)'),
  ('mail_sign_in_failed',      '{}', 'Mail sign-in failed (provider, error)'),
  ('mail_sign_out',            '{}', 'Mail account signed out'),
  ('mail_app_password_help',   '{}', 'Opened the app-password help'),
  ('mail_clean_tapped',        '{}', 'Mail cleanup action tapped'),
  ('mail_unsubscribe',         '{}', 'Unsubscribe from a sender tapped'),
  ('files_opened',             '{}', 'Files cleanup opened'),
  ('files_folder_added',       '{}', 'Folder added in Files cleanup'),
  ('compress_filter',          '{}', 'Filter changed in Compress')
ON CONFLICT (event_name) DO NOTHING;

-- Events of these names that arrived before they were in the catalog were parked as unknown_event — move them back.
INSERT INTO analytics.events (event_id, user_id, session_id, event_name, event_time, received_at, properties, app_version, platform)
SELECT DISTINCT ON (r.event_id) r.event_id, r.user_id, r.session_id, r.event_name, r.event_time, r.received_at, r.properties,
       COALESCE(r.app_version, 'unknown'), CASE WHEN r.platform = 'android' THEN 'android' ELSE 'ios' END
FROM analytics.events_rejected r
WHERE r.rejection_reason = 'unknown_event'
  AND r.event_name IN (SELECT event_name FROM analytics.event_catalog)
  AND r.event_id IS NOT NULL AND r.user_id IS NOT NULL AND r.session_id IS NOT NULL
  AND r.event_time BETWEEN now() - interval '90 days' AND now() + interval '1 day'
ON CONFLICT DO NOTHING;
DELETE FROM analytics.events_rejected
WHERE rejection_reason = 'unknown_event' AND event_name IN (SELECT event_name FROM analytics.event_catalog);

CREATE INDEX IF NOT EXISTS idx_users_last_seen ON analytics.users(last_seen_at DESC);

-- ───────────────────────── Helpers ─────────────────────────

-- Subscription state as shown in the CRM: active / trial / billing_issue / cancelled / expired / free
CREATE OR REPLACE FUNCTION analytics.crm_status(s analytics.subscription_status)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN s.user_id IS NULL THEN 'free'
        WHEN s.current_status IN ('billing_issue', 'in_grace_period') THEN 'billing_issue'
        WHEN s.is_active AND s.current_status = 'trial' THEN 'trial'
        WHEN s.is_active AND NOT s.will_renew THEN 'cancelled'
        WHEN s.is_active THEN 'active'
        ELSE 'expired' END
$$;

-- ───────────────────────── Entry point ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_crm(p_name TEXT, p_days INT DEFAULT 30, p_query TEXT DEFAULT NULL,
                                                p_user TEXT DEFAULT NULL, p_filter TEXT DEFAULT 'all', p_limit INT DEFAULT 100)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    since TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    lim INT := GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));
    q TEXT := NULLIF(lower(btrim(COALESCE(p_query, ''))), '');
    uid UUID;
    res JSONB;
BEGIN
    IF p_name = 'feedback_summary' THEN
        WITH ev AS (
            SELECT event_name, user_id, properties FROM events
            WHERE event_time >= since AND event_name IN ('rate_cleanup_shown', 'rate_cleanup_stars', 'rate_cleanup_skipped',
                  'rate_cleanup_feedback', 'review_prompt_shown', 'free_clean_gift_shown', 'free_clean_gift_accepted',
                  'free_clean_gift_declined', 'free_clean_gift_used')
        ), st AS (
            SELECT DISTINCT ON (user_id) user_id, (properties->>'stars')::int AS stars
            FROM ev WHERE event_name = 'rate_cleanup_stars' AND COALESCE(properties->>'stars', '') ~ '^[1-5]$'
        )
        SELECT jsonb_build_object(
            'shown',          (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'rate_cleanup_shown'),
            'rated',          (SELECT COUNT(*) FROM st),
            'avg_stars',      (SELECT ROUND(AVG(st.stars), 2) FROM st),
            'high',           (SELECT COUNT(*) FROM st WHERE st.stars >= 4),
            'low',            (SELECT COUNT(*) FROM st WHERE st.stars <= 3),
            'skipped',        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'rate_cleanup_skipped'),
            'with_text',      (SELECT COUNT(*) FROM ev WHERE event_name = 'rate_cleanup_feedback'),
            'system_prompts', (SELECT COUNT(*) FROM ev WHERE event_name = 'review_prompt_shown' AND properties->>'where' = 'free_clean_gift'),
            'stars',          (SELECT COALESCE(jsonb_agg(jsonb_build_object('stars', s, 'users',
                                   (SELECT COUNT(*) FROM st WHERE st.stars = s)) ORDER BY s DESC), '[]')
                               FROM generate_series(1, 5) s),
            'gift', jsonb_build_object(
                'shown',    (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'free_clean_gift_shown'),
                'accepted', (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'free_clean_gift_accepted'),
                'declined', (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'free_clean_gift_declined'),
                'used',     (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'free_clean_gift_used'),
                'bought_after', (SELECT COUNT(DISTINCT p.user_id) FROM payments p
                                 WHERE p.user_id IN (SELECT user_id FROM ev WHERE event_name = 'free_clean_gift_used')
                                   AND p.occurred_at >= since))
        ) INTO res;
        RETURN res;
    END IF;

    IF p_name = 'feedback' THEN
        SELECT COALESCE(jsonb_agg(x ORDER BY x->>'event_time' DESC), '[]') INTO res FROM (
            SELECT jsonb_build_object(
                'event_id', e.event_id, 'event_time', e.event_time, 'user_id', e.user_id,
                'stars', CASE WHEN COALESCE(e.properties->>'stars', '') ~ '^[1-5]$' THEN (e.properties->>'stars')::int END,
                'text', left(COALESCE(e.properties->>'text', ''), 1000),
                'country', u.country, 'app_version', e.app_version,
                'status', analytics.crm_status(s)) AS x
            FROM events e
            LEFT JOIN users u ON u.user_id = e.user_id
            LEFT JOIN subscription_status s ON s.user_id = e.user_id
            WHERE e.event_name = 'rate_cleanup_feedback' AND e.event_time >= since
              AND (q IS NULL OR lower(e.properties->>'text') LIKE '%' || q || '%')
            ORDER BY e.event_time DESC LIMIT lim) t;
        RETURN res;
    END IF;

    IF p_name = 'users' THEN
        SELECT COALESCE(jsonb_agg(x ORDER BY ord DESC), '[]') INTO res FROM (
            SELECT COALESCE(u.last_seen_at, u.created_at) AS ord, jsonb_build_object(
                'user_id', u.user_id, 'created_at', u.created_at, 'last_seen_at', u.last_seen_at, 'country', u.country,
                'app_version', COALESCE(ls.app_version, u.first_seen_app_version),
                'source', CASE WHEN a.is_organic = 'organic' THEN 'Organic' ELSE COALESCE(a.utm_source, CASE WHEN a.user_id IS NULL THEN NULL ELSE 'Paid' END) END,
                'campaign', COALESCE(a.campaign_name, a.campaign_id), 'organic', a.is_organic,
                'status', analytics.crm_status(s), 'product_id', s.product_id, 'will_renew', s.will_renew, 'expires_at', s.expires_at,
                'revenue_usd', (SELECT SUM(p.amount_usd) FROM payments p WHERE p.user_id = u.user_id),
                'sessions', (SELECT COUNT(*) FROM sessions x WHERE x.user_id = u.user_id),
                'stars', (SELECT (e.properties->>'stars')::int FROM events e WHERE e.user_id = u.user_id
                           AND e.event_name = 'rate_cleanup_stars' AND COALESCE(e.properties->>'stars', '') ~ '^[1-5]$'
                           ORDER BY e.event_time DESC LIMIT 1),
                'feedback', (SELECT left(e.properties->>'text', 200) FROM events e WHERE e.user_id = u.user_id
                              AND e.event_name = 'rate_cleanup_feedback' ORDER BY e.event_time DESC LIMIT 1)) AS x
            FROM users u
            LEFT JOIN subscription_status s ON s.user_id = u.user_id
            LEFT JOIN user_attribution a ON a.user_id = u.user_id
            LEFT JOIN LATERAL (SELECT app_version FROM sessions x WHERE x.user_id = u.user_id ORDER BY started_at DESC LIMIT 1) ls ON true
            WHERE (q IS NOT NULL AND (u.user_id::text LIKE q || '%' OR lower(COALESCE(u.adapty_profile_id, '')) LIKE q || '%'))
               OR (q IS NULL AND COALESCE(u.last_seen_at, u.created_at) >= since
                   AND CASE COALESCE(p_filter, 'all')
                       WHEN 'paying'   THEN analytics.crm_status(s) IN ('active', 'cancelled', 'billing_issue')
                       WHEN 'trial'    THEN analytics.crm_status(s) = 'trial'
                       WHEN 'churned'  THEN analytics.crm_status(s) IN ('expired', 'cancelled')
                       WHEN 'free'     THEN analytics.crm_status(s) = 'free'
                       WHEN 'feedback' THEN EXISTS (SELECT 1 FROM events e WHERE e.user_id = u.user_id
                                                    AND e.event_name IN ('rate_cleanup_stars', 'rate_cleanup_feedback'))
                       ELSE true END)
            ORDER BY COALESCE(u.last_seen_at, u.created_at) DESC
            LIMIT lim) t;
        RETURN res;
    END IF;

    IF p_name = 'user' THEN
        IF NOT analytics.is_uuid(p_user) THEN RETURN jsonb_build_object('error', 'bad user_id'); END IF;
        uid := p_user::uuid;
        IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = uid) THEN RETURN jsonb_build_object('error', 'not found'); END IF;
        SELECT jsonb_build_object(
            'profile', (SELECT jsonb_build_object('user_id', u.user_id, 'adapty_profile_id', u.adapty_profile_id,
                            'created_at', u.created_at, 'last_seen_at', u.last_seen_at, 'country', u.country,
                            'first_seen_app_version', u.first_seen_app_version, 'platform', u.platform)
                        FROM users u WHERE u.user_id = uid),
            'device', (SELECT jsonb_build_object('app_version', x.app_version, 'os_version', x.os_version, 'device_model', x.device_model,
                            'locale', x.locale, 'timezone', x.timezone, 'push_permission_granted', x.push_permission_granted,
                            'sessions', (SELECT COUNT(*) FROM sessions y WHERE y.user_id = uid),
                            'total_minutes', (SELECT ROUND(SUM(COALESCE(y.duration_seconds, 0)) / 60.0) FROM sessions y WHERE y.user_id = uid),
                            'is_premium', x.is_premium_at_start)
                       FROM sessions x WHERE x.user_id = uid ORDER BY x.started_at DESC LIMIT 1),
            'attribution', (SELECT to_jsonb(a) - 'user_id' FROM user_attribution a WHERE a.user_id = uid),
            'subscription', (SELECT (to_jsonb(s) - 'raw_payload' - 'user_id') || jsonb_build_object('crm_status', analytics.crm_status(s))
                             FROM subscription_status s WHERE s.user_id = uid),
            'payments', (SELECT COALESCE(jsonb_agg(jsonb_build_object('occurred_at', p.occurred_at, 'event_type', p.event_type,
                              'product_id', p.product_id, 'amount_usd', p.amount_usd, 'proceeds_usd', p.proceeds_usd,
                              'is_trial', p.is_trial, 'environment', p.environment, 'refund', r.status) ORDER BY p.occurred_at DESC), '[]')
                         FROM payments p LEFT JOIN refunds r ON r.payment_id = p.payment_id WHERE p.user_id = uid),
            'feedback', (SELECT COALESCE(jsonb_agg(jsonb_build_object('event_id', e.event_id, 'event_time', e.event_time, 'event_name', e.event_name,
                              'stars', e.properties->>'stars', 'text', left(COALESCE(e.properties->>'text', ''), 1000)) ORDER BY e.event_time DESC), '[]')
                         FROM events e WHERE e.user_id = uid AND e.event_name IN ('rate_cleanup_stars', 'rate_cleanup_feedback')),
            'events', (SELECT COALESCE(jsonb_agg(jsonb_build_object('event_time', t.event_time, 'event_name', t.event_name,
                            'properties', t.properties, 'app_version', t.app_version) ORDER BY t.event_time DESC), '[]')
                       FROM (SELECT event_time, event_name, properties, app_version FROM events
                             WHERE user_id = uid ORDER BY event_time DESC LIMIT 300) t)
        ) INTO res;
        RETURN res;
    END IF;

    RETURN jsonb_build_object('error', 'unknown report: ' || COALESCE(p_name, ''));
END $$;

REVOKE ALL ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT) TO service_role;
    END IF;
END $$;
