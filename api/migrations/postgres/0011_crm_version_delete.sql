-- X Clean — CRM v2: app-version filter, delete a user's whole rating (stars + review), delete a star bucket.
-- Run after 0010. Idempotent. Replaces analytics_crm with a 7-argument version (p_version added); the period comes
-- from analytics.range_t0/t1 (0007: calendar range headers or last p_days days).
--
--   public.analytics_crm(p_name, p_days, p_query, p_user, p_filter, p_limit, p_version)
--     version_list     → [{app_version, users}] for the period
--     feedback_summary / feedback / users / user — as before, filtered by p_version when given
--   public.analytics_crm_delete(p_event_id)                 → deletes the rating of the user who wrote that review
--   public.analytics_crm_delete_stars(p_stars, p_days, p_version) → deletes the ratings of users whose last rating = p_stars

DROP FUNCTION IF EXISTS public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.analytics_crm(p_name TEXT, p_days INT DEFAULT 30, p_query TEXT DEFAULT NULL,
                                                p_user TEXT DEFAULT NULL, p_filter TEXT DEFAULT 'all', p_limit INT DEFAULT 100,
                                                p_version TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    since TIMESTAMPTZ := analytics.range_t0(p_days);
    until_ts TIMESTAMPTZ := analytics.range_t1();
    lim INT := GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));
    q TEXT := NULLIF(lower(btrim(COALESCE(p_query, ''))), '');
    ver TEXT := NULLIF(left(btrim(COALESCE(p_version, '')), 32), '');
    uid UUID;
    res JSONB;
BEGIN
    IF p_name = 'version_list' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('app_version', app_version, 'users', users) ORDER BY
                   string_to_array(regexp_replace(app_version, '[^0-9.]', '', 'g'), '.')::int[] DESC), '[]') INTO res
        FROM (SELECT app_version, COUNT(DISTINCT user_id) AS users FROM sessions
              WHERE started_at >= since AND started_at < until_ts AND app_version ~ '^[0-9]+(\.[0-9]+)*$' GROUP BY 1) v;
        RETURN res;
    END IF;

    IF p_name = 'feedback_summary' THEN
        WITH ev AS (
            SELECT event_name, user_id, event_time, properties FROM events
            WHERE event_time >= since AND event_time < until_ts AND (ver IS NULL OR app_version = ver)
              AND event_name IN ('rate_cleanup_shown', 'rate_cleanup_stars', 'rate_cleanup_skipped',
                  'rate_cleanup_feedback', 'review_prompt_shown', 'free_clean_gift_shown', 'free_clean_gift_accepted',
                  'free_clean_gift_declined', 'free_clean_gift_used')
        ), st AS (
            -- the user's LAST rating in the period (same rule as analytics_crm_delete_stars)
            SELECT DISTINCT ON (user_id) user_id, (properties->>'stars')::int AS stars
            FROM ev WHERE event_name = 'rate_cleanup_stars' AND COALESCE(properties->>'stars', '') ~ '^[1-5]$'
            ORDER BY user_id, event_time DESC
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
                                   AND p.occurred_at >= since AND p.occurred_at < until_ts))
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
            WHERE e.event_name = 'rate_cleanup_feedback' AND e.event_time >= since AND e.event_time < until_ts
              AND (ver IS NULL OR e.app_version = ver)
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
            WHERE (ver IS NULL OR COALESCE(ls.app_version, u.first_seen_app_version) = ver)
              AND ((q IS NOT NULL AND (u.user_id::text LIKE q || '%' OR lower(COALESCE(u.adapty_profile_id, '')) LIKE q || '%'))
               OR (q IS NULL AND COALESCE(u.last_seen_at, u.created_at) >= since AND u.created_at < until_ts
                   AND CASE COALESCE(p_filter, 'all')
                       WHEN 'paying'   THEN analytics.crm_status(s) IN ('active', 'cancelled', 'billing_issue')
                       WHEN 'trial'    THEN analytics.crm_status(s) = 'trial'
                       WHEN 'churned'  THEN analytics.crm_status(s) IN ('expired', 'cancelled')
                       WHEN 'free'     THEN analytics.crm_status(s) = 'free'
                       WHEN 'feedback' THEN EXISTS (SELECT 1 FROM events e WHERE e.user_id = u.user_id
                                                    AND e.event_name IN ('rate_cleanup_stars', 'rate_cleanup_feedback'))
                       ELSE true END))
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

-- Everything a user left on the in-app rating screen (stars, review, shown/skipped, the system prompt after it).
CREATE OR REPLACE FUNCTION analytics.delete_rating_of(uid UUID) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
    DELETE FROM analytics.events WHERE user_id = uid
      AND (event_name IN ('rate_cleanup_shown', 'rate_cleanup_stars', 'rate_cleanup_skipped', 'rate_cleanup_feedback')
           OR (event_name = 'review_prompt_shown' AND properties->>'where' = 'free_clean_gift'));
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- Delete by a review's event_id: removes that user's whole rating. Returns rows deleted.
CREATE OR REPLACE FUNCTION public.analytics_crm_delete(p_event_id TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE uid UUID;
BEGIN
    IF NOT analytics.is_uuid(p_event_id) THEN RETURN 0; END IF;
    SELECT user_id INTO uid FROM events WHERE event_id = p_event_id::uuid
      AND event_name IN ('rate_cleanup_feedback', 'rate_cleanup_stars') LIMIT 1;
    IF uid IS NULL THEN RETURN 0; END IF;
    RETURN analytics.delete_rating_of(uid);
END $$;

-- Delete a whole star bucket (all users whose latest rating in the period = p_stars). Returns users affected.
CREATE OR REPLACE FUNCTION public.analytics_crm_delete_stars(p_stars INT, p_days INT DEFAULT 30, p_version TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    since TIMESTAMPTZ := analytics.range_t0(p_days);
    until_ts TIMESTAMPTZ := analytics.range_t1();
    ver TEXT := NULLIF(left(btrim(COALESCE(p_version, '')), 32), '');
    u UUID; n INT := 0;
BEGIN
    IF p_stars IS NULL OR p_stars < 1 OR p_stars > 5 THEN RETURN 0; END IF;
    FOR u IN
        SELECT user_id FROM (
            SELECT DISTINCT ON (user_id) user_id, (properties->>'stars')::int AS stars FROM events
            WHERE event_name = 'rate_cleanup_stars' AND COALESCE(properties->>'stars', '') ~ '^[1-5]$'
              AND event_time >= since AND event_time < until_ts AND (ver IS NULL OR app_version = ver)
            ORDER BY user_id, event_time DESC) x
        WHERE stars = p_stars
    LOOP
        PERFORM analytics.delete_rating_of(u);
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.analytics_crm_delete(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.analytics_crm_delete_stars(INT, INT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT, TEXT) FROM anon, authenticated;
        REVOKE ALL ON FUNCTION public.analytics_crm_delete(TEXT) FROM anon, authenticated;
        REVOKE ALL ON FUNCTION public.analytics_crm_delete_stars(INT, INT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT, TEXT) TO service_role;
        GRANT EXECUTE ON FUNCTION public.analytics_crm_delete(TEXT) TO service_role;
        GRANT EXECUTE ON FUNCTION public.analytics_crm_delete_stars(INT, INT, TEXT) TO service_role;
    END IF;
END $$;
