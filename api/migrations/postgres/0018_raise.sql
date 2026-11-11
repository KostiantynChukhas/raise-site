-- 0018: Raise (Words on Apple Watch) on top of the X Clean analytics schema (0001–0017 are copied 1:1 from cleanx-web).
-- Idempotent. What changes:
--   1. Event catalog: Raise in-app events (practice, faces, sets, words) + the "free Pro day" gift.
--      The gift / rating screen keep the X Clean event names (free_clean_gift_* / rate_cleanup_*), so the CRM,
--      Reviews and rating A/B reports work unchanged:  free_clean_gift_shown  = «Ты счастливчик — 1 день Pro бесплатно» shown,
--      free_clean_gift_accepted = gift taken, free_clean_gift_used = the free Pro day was activated.
--   2. property_enums: Raise tabs; scan_type is not used by Raise.
--   3. Reports: "used the product" = practice_completed / face_installed / set_created (instead of scan / cleanup),
--      engagement breakdown by practice mode.

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('practice_started',     '{mode}', 'Practice / game started (mode = daily, review, flashcards, speed, match, set)'),
  ('practice_completed',   '{mode}', 'Practice / game finished (correct, total, score)'),
  ('word_learned',         '{}',     'Word moved to learned'),
  ('face_installed',       '{}',     'Watch face sent to Apple Watch / Photos'),
  ('face_created',         '{}',     'Custom face designed in the editor'),
  ('set_created',          '{source}', 'Word set created (source = ai, import, manual)'),
  ('set_opened',           '{}',     'Word set opened'),
  ('level_check_completed','{level}', 'Placement test finished'),
  ('language_changed',     '{}',     'Learning / native language changed (from, to)'),
  ('daily_goal_changed',   '{}',     'Daily words goal changed'),
  ('achievement_unlocked', '{}',     'Achievement unlocked (id)'),
  ('free_day_started',     '{}',     'The free Pro day from the gift is active (until)'),
  ('free_day_ended',       '{}',     'The free Pro day expired')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

UPDATE analytics.event_catalog SET description = 'Gift «1 day of Pro for free» offered (paywall + special offer closed without buying)' WHERE event_name = 'free_clean_gift_shown';
UPDATE analytics.event_catalog SET description = 'Gift «1 day of Pro» accepted' WHERE event_name = 'free_clean_gift_accepted';
UPDATE analytics.event_catalog SET description = 'Gift «1 day of Pro» declined' WHERE event_name = 'free_clean_gift_declined';
UPDATE analytics.event_catalog SET description = 'Free Pro day activated after the rating screen' WHERE event_name = 'free_clean_gift_used';
UPDATE analytics.event_catalog SET description = 'In-app «How do you like Raise?» screen shown' WHERE event_name = 'rate_cleanup_shown';

INSERT INTO analytics.property_enums (property, allowed) VALUES
  ('tab', '{today,practice,sets,faces,settings}')
ON CONFLICT (property) DO UPDATE SET allowed = EXCLUDED.allowed;
DELETE FROM analytics.property_enums WHERE property = 'scan_type';

-- Events that arrived before this migration as unknown → move them back (same trick as 0006).
INSERT INTO analytics.events (event_id, user_id, session_id, event_name, event_time, received_at, properties, app_version, platform)
SELECT r.event_id, r.user_id, r.session_id, r.event_name, r.event_time, r.received_at, r.properties, r.app_version, r.platform
FROM analytics.events_rejected r
WHERE r.rejection_reason = 'unknown_event' AND r.event_id IS NOT NULL AND r.user_id IS NOT NULL AND r.session_id IS NOT NULL
  AND r.event_time IS NOT NULL AND r.app_version IS NOT NULL AND r.platform IN ('ios', 'android')
  AND r.event_name IN (SELECT event_name FROM analytics.event_catalog)
  AND EXISTS (SELECT 1 FROM analytics.users u WHERE u.user_id = r.user_id)
ON CONFLICT DO NOTHING;
DELETE FROM analytics.events_rejected
WHERE rejection_reason = 'unknown_event' AND event_name IN (SELECT event_name FROM analytics.event_catalog);

-- Patch the report functions in place (their current definitions, whatever migration created them).
DO $patch$
DECLARE
    fn  REGPROCEDURE;
    src TEXT;
    old TEXT;
BEGIN
    FOREACH fn IN ARRAY ARRAY[
        'public.analytics_growth(text,integer,text,text)'::regprocedure,
        'public.analytics_ab(text,integer,text,text,text)'::regprocedure,
        'public.analytics_report(text,integer)'::regprocedure]
    LOOP
        src := pg_get_functiondef(fn);
        old := src;
        -- "used the product"
        src := replace(src, $q$'scan_completed', 'cleanup_completed', 'fast_clean_completed'$q$,
                            $q$'practice_completed', 'face_installed', 'set_created'$q$);
        src := replace(src, 'Сканировали / чистили', 'Учили слова / поставили циферблат');
        -- engagement: per practice mode instead of per scan type
        src := replace(src, $q$WHEN e.event_name IN ('scan_completed', 'cleanup_completed') THEN e.event_name || ':' || COALESCE(e.properties->>'scan_type', '?')$q$,
                            $q$WHEN e.event_name IN ('practice_completed', 'practice_started') THEN e.event_name || ':' || COALESCE(e.properties->>'mode', '?')$q$);
        src := replace(src, $q$'charging_animation_selected',$q$, $q$'practice_started', 'word_learned', 'face_created', 'set_opened', 'level_check_completed', 'achievement_unlocked',$q$);
        src := replace(src, $q$'charging_animation_shown', 'widget_selected', 'widget_installed',$q$, $q$'language_changed', 'daily_goal_changed', 'free_day_started',$q$);
        IF src <> old THEN EXECUTE src; END IF;
    END LOOP;
END $patch$;
