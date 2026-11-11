-- X Clean — launch_action event: a link asked the app to do something (showRating / offer / security). Idempotent.
INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('launch_action', '{action}', 'Link action performed (action = showrating / offer / security; source = scheme / link / deferred)')
ON CONFLICT (event_name) DO NOTHING;
