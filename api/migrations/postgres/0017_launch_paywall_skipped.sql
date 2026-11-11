-- X Clean — event catalog: launch_paywall_skipped (app 2.8, 2nd-launch paywall skip experiment).
-- Run after 0016. Idempotent: safe to run again.
--
--   1. Event catalog: launch_paywall_skipped (properties: launch = the launch number that was skipped).
--      Events of this name that arrived earlier were parked as unknown_event — moved back below.

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('launch_paywall_skipped', '{}', 'Launch paywall skipped on the 2nd launch for the scan-first group (launch = launch number)')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

INSERT INTO analytics.events (event_id, user_id, session_id, event_name, event_time, received_at, properties, app_version, platform)
SELECT DISTINCT ON (r.event_id) r.event_id, r.user_id, r.session_id, r.event_name, r.event_time, r.received_at, r.properties,
       COALESCE(r.app_version, 'unknown'), CASE WHEN r.platform = 'android' THEN 'android' ELSE 'ios' END
FROM analytics.events_rejected r
WHERE r.rejection_reason = 'unknown_event'
  AND r.event_name = 'launch_paywall_skipped'
  AND r.event_id IS NOT NULL AND r.user_id IS NOT NULL AND r.session_id IS NOT NULL
  AND r.event_time BETWEEN now() - interval '90 days' AND now() + interval '1 day'
ON CONFLICT DO NOTHING;
DELETE FROM analytics.events_rejected
WHERE rejection_reason = 'unknown_event' AND event_name = 'launch_paywall_skipped';
