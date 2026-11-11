-- 0014: clear the "free gift cleanup" funnel from /admin → Отзывы.
--   public.analytics_crm_delete_gift(p_step, p_days, p_version) → deletes free_clean_gift_* events
--   in the selected period / app version. p_step: shown|accepted|declined|used|all.
--   Also drops the related system-review prompt rows (review_prompt_shown where=free_clean_gift) for 'all'.
--   Returns the number of deleted event rows.

CREATE OR REPLACE FUNCTION public.analytics_crm_delete_gift(p_step TEXT DEFAULT 'all', p_days INT DEFAULT 30, p_version TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    since TIMESTAMPTZ := analytics.range_t0(p_days);
    until_ts TIMESTAMPTZ := analytics.range_t1();
    ver TEXT := NULLIF(left(btrim(COALESCE(p_version, '')), 32), '');
    step TEXT := lower(btrim(COALESCE(p_step, 'all')));
    names TEXT[];
    n INT := 0;
BEGIN
    names := CASE step
        WHEN 'shown'    THEN ARRAY['free_clean_gift_shown']
        WHEN 'accepted' THEN ARRAY['free_clean_gift_accepted']
        WHEN 'declined' THEN ARRAY['free_clean_gift_declined']
        WHEN 'used'     THEN ARRAY['free_clean_gift_used']
        WHEN 'all'      THEN ARRAY['free_clean_gift_shown', 'free_clean_gift_accepted', 'free_clean_gift_declined', 'free_clean_gift_used']
        ELSE NULL END;
    IF names IS NULL THEN RETURN 0; END IF;

    DELETE FROM events
    WHERE event_name = ANY(names)
      AND event_time >= since AND event_time < until_ts AND (ver IS NULL OR app_version = ver);
    GET DIAGNOSTICS n = ROW_COUNT;

    IF step = 'all' THEN
        DELETE FROM events
        WHERE event_name = 'review_prompt_shown' AND properties->>'where' IN ('free_clean_gift', 'show_rating', 'deep_link')
          AND event_time >= since AND event_time < until_ts AND (ver IS NULL OR app_version = ver);
    END IF;
    RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.analytics_crm_delete_gift(TEXT, INT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_crm_delete_gift(TEXT, INT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_crm_delete_gift(TEXT, INT, TEXT) TO service_role;
    END IF;
END $$;
