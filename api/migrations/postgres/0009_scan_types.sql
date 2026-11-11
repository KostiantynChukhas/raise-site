-- X Clean — allow scan_type = mail / files (Mail and Files cleanup) and trigger = post_scan; move back what was rejected.
-- Run after 0008. Idempotent.
UPDATE analytics.property_enums SET allowed = (SELECT ARRAY(SELECT DISTINCT unnest(allowed || ARRAY['mail', 'files'])))
WHERE property = 'scan_type' AND NOT (ARRAY['mail', 'files'] <@ allowed);
UPDATE analytics.property_enums SET allowed = (SELECT ARRAY(SELECT DISTINCT unnest(allowed || ARRAY['post_scan'])))
WHERE property = 'trigger' AND NOT ('post_scan' = ANY(allowed));

INSERT INTO analytics.events (event_id, user_id, session_id, event_name, event_time, received_at, properties, app_version, platform)
SELECT DISTINCT ON (r.event_id) r.event_id, r.user_id, r.session_id, r.event_name, r.event_time, r.received_at, r.properties,
       COALESCE(r.app_version, 'unknown'), CASE WHEN r.platform = 'android' THEN 'android' ELSE 'ios' END
FROM analytics.events_rejected r
WHERE r.rejection_reason IN ('bad_scan_type', 'bad_trigger')
  AND r.event_id IS NOT NULL AND r.user_id IS NOT NULL AND r.session_id IS NOT NULL
  AND r.event_time BETWEEN now() - interval '90 days' AND now() + interval '1 day'
  AND analytics.validate_event(jsonb_build_object('event_id', r.event_id, 'session_id', r.session_id, 'event_name', r.event_name,
                                                  'event_time', r.event_time, 'properties', r.properties)) IS NULL
ON CONFLICT DO NOTHING;
DELETE FROM analytics.events_rejected r
WHERE r.rejection_reason IN ('bad_scan_type', 'bad_trigger')
  AND analytics.validate_event(jsonb_build_object('event_id', r.event_id, 'session_id', r.session_id, 'event_name', r.event_name,
                                                  'event_time', r.event_time, 'properties', r.properties)) IS NULL;
