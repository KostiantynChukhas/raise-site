-- X Clean — /admin: «A/B тесты» (отчёт по экрану оценки) + «Только новые» в Пользователях.
-- Run after 0015. Idempotent: safe to run again.
--
--   1. Event catalog: rating_ab_assigned, rate_cleanup_submitted (app 2.6, RatingABTest / RateCleanupView variant B).
--      Events of these names that arrived earlier were parked as unknown_event — moved back below.
--   2. public.analytics_ab_rating('rating_summary', p_days) → one row per variant of the rating screen
--      (A, B, '-' = user outside the test): users who saw the screen, picked stars, pressed «Оценить», 4–5★ / 1–3★,
--      skipped without a rating, wrote feedback, got the App Store dialog. Period = analytics.range_t0/t1 (0007).
--   3. analytics_crm(users): new filter p_filter = 'new' → only users installed within the period.

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('rating_ab_assigned',   '{test,variant}', 'Rating-screen A/B variant assigned (test = ab_rating_test_name, variant = A/B)'),
  ('rate_cleanup_submitted', '{}',           'Variant B of the rating screen: «Rate & start cleaning» pressed (stars, rating_variant)')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

INSERT INTO analytics.events (event_id, user_id, session_id, event_name, event_time, received_at, properties, app_version, platform)
SELECT DISTINCT ON (r.event_id) r.event_id, r.user_id, r.session_id, r.event_name, r.event_time, r.received_at, r.properties,
       COALESCE(r.app_version, 'unknown'), CASE WHEN r.platform = 'android' THEN 'android' ELSE 'ios' END
FROM analytics.events_rejected r
WHERE r.rejection_reason = 'unknown_event'
  AND r.event_name IN ('rating_ab_assigned', 'rate_cleanup_submitted')
  AND r.event_id IS NOT NULL AND r.user_id IS NOT NULL AND r.session_id IS NOT NULL
  AND r.event_time BETWEEN now() - interval '90 days' AND now() + interval '1 day'
ON CONFLICT DO NOTHING;
DELETE FROM analytics.events_rejected
WHERE rejection_reason = 'unknown_event' AND event_name IN ('rating_ab_assigned', 'rate_cleanup_submitted');

-- ───────────────────────── Rating-screen A/B report ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_ab_rating(p_name TEXT DEFAULT 'rating_summary', p_days INT DEFAULT 30)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    since TIMESTAMPTZ := analytics.range_t0(p_days);
    until_ts TIMESTAMPTZ := analytics.range_t1();
    res JSONB;
BEGIN
    IF COALESCE(p_name, 'rating_summary') <> 'rating_summary' THEN
        RETURN jsonb_build_object('error', 'unknown report: ' || COALESCE(p_name, ''));
    END IF;

    WITH ev AS (
        SELECT user_id, event_name, event_time, properties,
               COALESCE(NULLIF(upper(properties->>'rating_variant'), ''), '-') AS variant
        FROM events
        WHERE event_time >= since AND event_time < until_ts
          AND event_name IN ('rate_cleanup_shown', 'rate_cleanup_stars', 'rate_cleanup_submitted', 'rate_cleanup_skipped',
                             'rate_cleanup_feedback', 'review_prompt_shown')
    ), uv AS (
        -- one variant per user: the screen they saw first in the period
        SELECT DISTINCT ON (user_id) user_id, variant FROM ev
        WHERE event_name = 'rate_cleanup_shown' ORDER BY user_id, event_time
    ), st AS (
        -- the user's LAST star choice in the period
        SELECT DISTINCT ON (user_id) user_id, (properties->>'stars')::int AS stars
        FROM ev WHERE event_name = 'rate_cleanup_stars' AND COALESCE(properties->>'stars', '') ~ '^[1-5]$'
        ORDER BY user_id, event_time DESC
    ), agg AS (
        SELECT uv.variant,
               COUNT(*) AS users,
               COUNT(st.user_id) AS picked,
               COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM ev x WHERE x.user_id = uv.user_id AND x.event_name = 'rate_cleanup_submitted')) AS submitted,
               COUNT(*) FILTER (WHERE st.stars >= 4) AS high,
               COUNT(*) FILTER (WHERE st.stars <= 3) AS low,
               COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM ev x WHERE x.user_id = uv.user_id AND x.event_name = 'rate_cleanup_skipped'
                                                AND COALESCE(x.properties->>'stars', '') = '')) AS skipped,
               COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM ev x WHERE x.user_id = uv.user_id AND x.event_name = 'rate_cleanup_feedback')) AS feedback,
               COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM ev x WHERE x.user_id = uv.user_id AND x.event_name = 'review_prompt_shown'
                                                AND x.properties->>'where' IN ('free_clean_gift', 'deep_link'))) AS system_prompt,
               ROUND(AVG(st.stars), 2) AS avg_stars
        FROM uv LEFT JOIN st ON st.user_id = uv.user_id
        GROUP BY uv.variant
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'variant', variant, 'users', users,
               'picked', picked,          'picked_pct',        ROUND(100.0 * picked / users, 1),
               'submitted', submitted,    'submitted_pct',     ROUND(100.0 * submitted / users, 1),
               'high', high,              'high_pct',          ROUND(100.0 * high / users, 1),
               'low', low,                'low_pct',           ROUND(100.0 * low / users, 1),
               'skipped', skipped,        'skipped_pct',       ROUND(100.0 * skipped / users, 1),
               'feedback', feedback,
               'system_prompt', system_prompt, 'system_pct',   ROUND(100.0 * system_prompt / users, 1),
               'avg_stars', avg_stars) ORDER BY variant), '[]') INTO res
    FROM agg;
    RETURN res;
END $$;

REVOKE ALL ON FUNCTION public.analytics_ab_rating(TEXT, INT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_ab_rating(TEXT, INT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_ab_rating(TEXT, INT) TO service_role;
    END IF;
END $$;

-- ───────────────────────── Users: «Только новые» ─────────────────────────
-- analytics_crm(users, p_filter = 'new') → only users whose install (created_at) falls within the period.
DO $patch$
DECLARE src TEXT;
BEGIN
    src := pg_get_functiondef('public.analytics_crm(text,integer,text,text,text,integer,text)'::regprocedure);
    IF position($q$WHEN 'new' THEN$q$ IN src) = 0 AND position($q$ELSE true END))$q$ IN src) > 0 THEN
        src := replace(src, $q$ELSE true END))$q$, $q$WHEN 'new' THEN u.created_at >= since
                       ELSE true END))$q$);
        EXECUTE src;
    END IF;
END $patch$;
