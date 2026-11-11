-- X Clean — any date range in /admin (one day or "from … to …" from the calendar), not only "last N days".
-- Run after 0006_crm_feedback.sql. Idempotent: safe to run again.
--
-- How it works: the Worker passes the range as HTTP headers X-Range-From / X-Range-To (ISO timestamps, the browser's
-- local midnights; To is exclusive). PostgREST exposes request headers to SQL as the `request.headers` setting, so the
-- report functions keep their signatures. Without the headers everything works as before (last p_days days).
--
-- The report functions from 0002–0006 are patched in place below (their period start was `now() - p_days` and most
-- queries had no upper bound). The patch is guarded, so running this file again changes nothing.

CREATE OR REPLACE FUNCTION analytics.range_hdr(k TEXT) RETURNS TIMESTAMPTZ LANGUAGE plpgsql STABLE AS $$
DECLARE h JSON;
BEGIN
    BEGIN
        h := NULLIF(current_setting('request.headers', true), '')::json;
    EXCEPTION WHEN others THEN RETURN NULL;
    END;
    RETURN analytics.try_ts(h->>k);
END $$;

-- Period start: X-Range-From, otherwise now() - p_days.
CREATE OR REPLACE FUNCTION analytics.range_t0(p_days INT) RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN analytics.range_hdr('x-range-from') IS NOT NULL AND analytics.range_hdr('x-range-to') > analytics.range_hdr('x-range-from')
                THEN analytics.range_hdr('x-range-from')
                ELSE now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730))) END
$$;

-- Period end (exclusive): X-Range-To, never later than now().
CREATE OR REPLACE FUNCTION analytics.range_t1() RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN analytics.range_hdr('x-range-from') IS NOT NULL AND analytics.range_hdr('x-range-to') > analytics.range_hdr('x-range-from')
                THEN LEAST(analytics.range_hdr('x-range-to'), now())
                ELSE now() END
$$;

-- Period length in whole days (for "previous period of the same length").
CREATE OR REPLACE FUNCTION analytics.range_days(p_days INT) RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN analytics.range_hdr('x-range-from') IS NOT NULL AND analytics.range_hdr('x-range-to') > analytics.range_hdr('x-range-from')
                THEN GREATEST(1, CEIL(EXTRACT(EPOCH FROM analytics.range_hdr('x-range-to') - analytics.range_hdr('x-range-from')) / 86400))::int
                ELSE GREATEST(1, LEAST(COALESCE(p_days, 30), 730)) END
$$;

DO $patch$
DECLARE
    f TEXT;
    src TEXT;
    orig TEXT;
    t0_old CONSTANT TEXT := 't0 TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));';
    since_old CONSTANT TEXT := 'since TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));';
    col CONSTANT TEXT := '((?:\m[a-z]\.)?(?:created_at|event_time|occurred_at|cancel_date))';
BEGIN
    FOREACH f IN ARRAY ARRAY[
        'public.analytics_growth(text,integer,text,text)',
        'public.analytics_release(text,integer,text,text)',
        'public.analytics_billing(text,integer,text,text)',
        'public.analytics_ab(text,integer,text,text,text)',
        'analytics.release_trials(timestamptz,text,text)',
        'public.analytics_crm(text,integer,text,text,text,integer)'] LOOP
        IF to_regprocedure(f) IS NULL THEN CONTINUE; END IF;
        src := pg_get_functiondef(to_regprocedure(f));
        orig := src;

        -- period start / end
        src := replace(src, 'd INT := GREATEST(1, LEAST(COALESCE(p_days, 30), 730));', 'd INT := analytics.range_days(p_days);');
        src := replace(src, 't1 TIMESTAMPTZ := now();', 't1 TIMESTAMPTZ := analytics.range_t1();');
        IF position('t1 TIMESTAMPTZ' IN src) > 0 THEN
            src := replace(src, t0_old, 't0 TIMESTAMPTZ := analytics.range_t0(p_days);');
        ELSE
            src := replace(src, t0_old, 't0 TIMESTAMPTZ := analytics.range_t0(p_days);' || chr(10) || '    t1 TIMESTAMPTZ := analytics.range_t1();');
        END IF;
        src := replace(src, since_old, 'since TIMESTAMPTZ := analytics.range_t0(p_days);' || chr(10) || '    until_ts TIMESTAMPTZ := analytics.range_t1();');

        -- upper bound for every "x >= t0" / "x >= since" that has none
        IF f LIKE 'analytics.release_trials%' THEN
            src := regexp_replace(src, col || ' >= t0(?![[:alnum:]_:])(?!\s*-)(?! AND (?:[a-z]\.)?(?:created_at|event_time|occurred_at|cancel_date|date) < )', '\1 >= t0 AND \1 < analytics.range_t1()', 'g');
        ELSIF f LIKE 'public.analytics_crm%' THEN
            src := regexp_replace(src, col || ' >= since(?! AND (?:[a-z]\.)?(?:created_at|event_time|occurred_at|cancel_date|date) < )', '\1 >= since AND \1 < until_ts', 'g');
            src := replace(src, 'COALESCE(u.last_seen_at, u.created_at) >= since' || chr(10),
                                'COALESCE(u.last_seen_at, u.created_at) >= since AND u.created_at < until_ts' || chr(10));
        ELSE
            src := regexp_replace(src, col || ' >= t0(?![[:alnum:]_:])(?!\s*-)(?! AND (?:[a-z]\.)?(?:created_at|event_time|occurred_at|cancel_date|date) < )', '\1 >= t0 AND \1 < t1', 'g');
            src := regexp_replace(src, '\mdate >= t0::date(?! AND (?:[a-z]\.)?(?:created_at|event_time|occurred_at|cancel_date|date) < )', 'date >= t0::date AND date < t1::date', 'g');
        END IF;

        IF src <> orig THEN
            EXECUTE src;
            RAISE NOTICE 'patched %', f;
        END IF;
    END LOOP;
END $patch$;
