-- X Clean — delete a review from /admin → Отзывы (test reviews, spam). Run after 0009. Idempotent.
--
-- * analytics_crm 'feedback' and 'user'.feedback now return event_id (patched in place for existing DBs).
-- * public.analytics_crm_delete(p_event_id) removes one rate_cleanup_feedback event; returns rows deleted (0/1).

DO $patch$
DECLARE src TEXT; orig TEXT;
BEGIN
    IF to_regprocedure('public.analytics_crm(text,integer,text,text,text,integer)') IS NULL THEN RETURN; END IF;
    src := pg_get_functiondef('public.analytics_crm(text,integer,text,text,text,integer)'::regprocedure);
    orig := src;
    IF position('''event_id'', e.event_id, ''event_time'', e.event_time, ''user_id''' IN src) = 0 THEN
        src := replace(src, '''event_time'', e.event_time, ''user_id'', e.user_id,',
                            '''event_id'', e.event_id, ''event_time'', e.event_time, ''user_id'', e.user_id,');
    END IF;
    IF position('jsonb_build_object(''event_id'', e.event_id, ''event_time'', e.event_time, ''event_name''' IN src) = 0 THEN
        src := replace(src, 'jsonb_build_object(''event_time'', e.event_time, ''event_name'', e.event_name,',
                            'jsonb_build_object(''event_id'', e.event_id, ''event_time'', e.event_time, ''event_name'', e.event_name,');
    END IF;
    IF src <> orig THEN EXECUTE src; RAISE NOTICE 'analytics_crm: event_id added'; END IF;
END $patch$;

CREATE OR REPLACE FUNCTION public.analytics_crm_delete(p_event_id TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE n INT;
BEGIN
    IF NOT analytics.is_uuid(p_event_id) THEN RETURN 0; END IF;
    DELETE FROM events WHERE event_id = p_event_id::uuid AND event_name = 'rate_cleanup_feedback';
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.analytics_crm_delete(TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_crm_delete(TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_crm_delete(TEXT) TO service_role;
    END IF;
END $$;
