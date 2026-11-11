-- X Clean — fix: analytics from returning users was lost (D1 retention showed ~0%, App Store Connect shows ~29%).
-- Run after 0007_date_range.sql. Idempotent: safe to run again.
--
-- Bug: analytics_ingest computed sessions.is_reengagement as `n > 1 AND entry IN (...)`. For the 2nd+ session of a user
-- opened normally (no push / deep link) entry is NULL → the expression is NULL → NOT NULL violation → the whole batch
-- failed. The Worker parked those batches in KV (7-day TTL) and the cron replay stopped at the first failing one.
-- After this fix the cron replays the parked batches (last 7 days of data come back within a few hours).

DO $fix$
DECLARE
    src TEXT;
BEGIN
    IF to_regprocedure('public.analytics_ingest(jsonb,text)') IS NULL THEN RETURN; END IF;
    src := pg_get_functiondef('public.analytics_ingest(jsonb,text)'::regprocedure);
    IF position('COALESCE(entry IN (''push'', ''notification'', ''deep_link''), false)' IN src) > 0 THEN RETURN; END IF;
    src := replace(src, 'n > 1 AND entry IN (''push'', ''notification'', ''deep_link'')',
                        'n > 1 AND COALESCE(entry IN (''push'', ''notification'', ''deep_link''), false)');
    EXECUTE src;
    RAISE NOTICE 'analytics_ingest patched';
END $fix$;
