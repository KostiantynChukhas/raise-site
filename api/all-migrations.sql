-- X Clean — product analytics schema for Supabase (PostgreSQL ≥ 14).
-- Implements the TZ tables 1:1 (users, user_attribution, sessions, events [partitioned], events_rejected,
-- payments, subscription_status, refunds) + ad_spend (CAC/ROAS), event_catalog, integration_anomalies, webhook_log.
--
-- Security model:
--   * All tables live in schema "analytics" — NOT exposed by Supabase's REST API.
--   * The Cloudflare Worker calls a few SECURITY DEFINER functions in "public" via /rest/v1/rpc/* with the
--     service_role key (a Worker secret). EXECUTE is revoked from anon/authenticated, so the public anon key can't call them.
--   * bi_readonly role: SELECT without PII / raw payloads (TZ 2.6).
--
-- Idempotent: safe to run again (CREATE ... IF NOT EXISTS / CREATE OR REPLACE).

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS analytics;

-- ───────────────────────── Tables ─────────────────────────

CREATE TABLE IF NOT EXISTS analytics.users (
    user_id                 UUID PRIMARY KEY,                 -- generated on the device (Keychain), = Adapty customer_user_id
    anonymous_id            UUID NOT NULL UNIQUE,
    apple_id                TEXT,
    adapty_profile_id       TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at            TIMESTAMPTZ,
    first_seen_app_version  TEXT NOT NULL,
    country                 TEXT,
    ip                      INET,                             -- kept NULL on purpose (only country is stored)
    platform                TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_users_created_at ON analytics.users(created_at);

CREATE TABLE IF NOT EXISTS analytics.user_attribution (
    user_id             UUID PRIMARY KEY REFERENCES analytics.users(user_id) ON DELETE CASCADE,
    install_at          TIMESTAMPTZ NOT NULL,
    utm_source          TEXT,
    campaign_id         TEXT,
    campaign_name       TEXT,
    adset_id            TEXT,
    adset_name          TEXT,
    ad_id               TEXT,
    ad_name             TEXT,
    attribution_source  TEXT NOT NULL DEFAULT 'appsflyer',
    is_organic          TEXT NOT NULL CHECK (is_organic IN ('organic', 'paid_attributed', 'paid_unattributed'))
);
CREATE INDEX IF NOT EXISTS idx_attribution_utm_source ON analytics.user_attribution(utm_source);
CREATE INDEX IF NOT EXISTS idx_attribution_campaign ON analytics.user_attribution(campaign_id);

CREATE TABLE IF NOT EXISTS analytics.sessions (
    session_id              UUID PRIMARY KEY,
    user_id                 UUID NOT NULL REFERENCES analytics.users(user_id) ON DELETE CASCADE,
    session_number          INT NOT NULL,
    started_at              TIMESTAMPTZ NOT NULL,
    ended_at                TIMESTAMPTZ,
    duration_seconds        INT,
    is_premium_at_start     BOOLEAN NOT NULL,
    app_version             TEXT NOT NULL,
    platform                TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
    os_version              TEXT,
    device_model            TEXT,
    idfv                    TEXT,
    push_token              TEXT,
    push_permission_granted BOOLEAN,
    locale                  TEXT,
    timezone                TEXT,
    ip_address              INET,                             -- NULL on purpose (privacy); country comes from Cloudflare
    country_code            TEXT,
    is_vpn_or_proxy         BOOLEAN,
    entry_source            TEXT,
    entry_utm_source        TEXT,
    is_reengagement         BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON analytics.sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_started_at ON analytics.sessions(started_at);
CREATE INDEX IF NOT EXISTS idx_sessions_open ON analytics.sessions(started_at) WHERE ended_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_user_session_number ON analytics.sessions(user_id, session_number);

-- events: partitioned by month (TZ 6). PK must contain the partition key → (event_id, event_time).
-- The client resends an event with the same event_id AND event_time, so ON CONFLICT dedups retries.
CREATE TABLE IF NOT EXISTS analytics.events (
    event_id      UUID NOT NULL,
    user_id       UUID NOT NULL,
    session_id    UUID NOT NULL,
    event_name    TEXT NOT NULL,
    event_time    TIMESTAMPTZ NOT NULL,
    received_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    properties    JSONB NOT NULL DEFAULT '{}',
    app_version   TEXT NOT NULL,
    platform      TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
    PRIMARY KEY (event_id, event_time)
) PARTITION BY RANGE (event_time);
CREATE INDEX IF NOT EXISTS idx_events_user_id ON analytics.events(user_id, event_time);
CREATE INDEX IF NOT EXISTS idx_events_session_id ON analytics.events(session_id);
CREATE INDEX IF NOT EXISTS idx_events_event_name ON analytics.events(event_name, event_time);
CREATE INDEX IF NOT EXISTS idx_events_received_at ON analytics.events(received_at);
CREATE INDEX IF NOT EXISTS idx_events_properties_gin ON analytics.events USING GIN (properties);
-- Safety net: events with a clock far in the past/future land here instead of failing the INSERT.
CREATE TABLE IF NOT EXISTS analytics.events_default PARTITION OF analytics.events DEFAULT;

CREATE TABLE IF NOT EXISTS analytics.events_rejected (
    event_id          UUID,
    user_id           UUID,
    session_id        UUID,
    event_name        TEXT NOT NULL,
    event_time        TIMESTAMPTZ,
    received_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    properties        JSONB NOT NULL DEFAULT '{}',
    app_version       TEXT,
    platform          TEXT,
    rejection_reason  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_rejected_event_name ON analytics.events_rejected(event_name, received_at);
CREATE INDEX IF NOT EXISTS idx_events_rejected_received ON analytics.events_rejected(received_at);

CREATE TABLE IF NOT EXISTS analytics.payments (
    payment_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id           TEXT NOT NULL UNIQUE,
    user_id                  UUID NOT NULL REFERENCES analytics.users(user_id) ON DELETE CASCADE,
    product_id               TEXT NOT NULL,
    event_type               TEXT NOT NULL CHECK (event_type IN
                              ('trial_start', 'trial_converted', 'initial_purchase', 'renewal',
                               'billing_retry', 'one_time_purchase')),
    is_recurring             BOOLEAN NOT NULL DEFAULT true,
    amount_usd               NUMERIC(10,2),
    proceeds_usd             NUMERIC(10,2),
    currency                 TEXT,
    original_transaction_id  TEXT NOT NULL,
    occurred_at              TIMESTAMPTZ NOT NULL,
    is_trial                 BOOLEAN NOT NULL DEFAULT false,
    environment              TEXT,
    raw_payload              JSONB
);
CREATE INDEX IF NOT EXISTS idx_payments_user_id ON analytics.payments(user_id);
CREATE INDEX IF NOT EXISTS idx_payments_original_txn ON analytics.payments(original_transaction_id);
CREATE INDEX IF NOT EXISTS idx_payments_occurred_at ON analytics.payments(occurred_at);

CREATE TABLE IF NOT EXISTS analytics.subscription_status (
    user_id                 UUID PRIMARY KEY REFERENCES analytics.users(user_id) ON DELETE CASCADE,
    original_transaction_id TEXT NOT NULL,
    product_id              TEXT NOT NULL,
    current_status          TEXT NOT NULL CHECK (current_status IN
                             ('trial', 'active', 'in_grace_period', 'billing_issue',
                              'cancelled', 'expired', 'paused')),
    is_active               BOOLEAN NOT NULL,
    will_renew              BOOLEAN NOT NULL,
    expires_at              TIMESTAMPTZ,
    cancel_date             TIMESTAMPTZ,
    cancellation_reason     TEXT,
    raw_payload             JSONB,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_subscription_status_is_active ON analytics.subscription_status(is_active);
CREATE INDEX IF NOT EXISTS idx_subscription_status_expires_at ON analytics.subscription_status(expires_at);

CREATE TABLE IF NOT EXISTS analytics.refunds (
    refund_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id   UUID NOT NULL UNIQUE REFERENCES analytics.payments(payment_id) ON DELETE CASCADE,
    status       TEXT NOT NULL CHECK (status IN ('requested', 'approved', 'rejected', 'processed')),
    amount_usd   NUMERIC(10,2),
    reason       TEXT,
    requested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ,
    raw_payload  JSONB
);
CREATE INDEX IF NOT EXISTS idx_refunds_status ON analytics.refunds(status);

-- Ad spend per day/campaign — without it CAC/ROAS can't be computed.
CREATE TABLE IF NOT EXISTS analytics.ad_spend (
    date          DATE NOT NULL,
    source        TEXT NOT NULL,
    campaign_id   TEXT NOT NULL DEFAULT '',
    campaign_name TEXT,
    adset_id      TEXT NOT NULL DEFAULT '',
    adset_name    TEXT,
    spend_usd     NUMERIC(12,2) NOT NULL,
    impressions   INT,
    clicks        INT,
    installs      INT,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (date, source, campaign_id, adset_id)
);

CREATE TABLE IF NOT EXISTS analytics.integration_anomalies (
    id          BIGSERIAL PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    kind        TEXT NOT NULL,
    details     TEXT,
    raw_payload JSONB
);

CREATE TABLE IF NOT EXISTS analytics.webhook_log (
    id          BIGSERIAL PRIMARY KEY,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source      TEXT NOT NULL,
    event_type  TEXT,
    status      TEXT NOT NULL,
    error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_webhook_log_received ON analytics.webhook_log(received_at);

-- Event catalog: required properties ("*" in the TZ) + allowed values. Editable without a deploy.
CREATE TABLE IF NOT EXISTS analytics.event_catalog (
    event_name  TEXT PRIMARY KEY,
    required    TEXT[] NOT NULL DEFAULT '{}',
    description TEXT
);
CREATE TABLE IF NOT EXISTS analytics.property_enums (
    property TEXT PRIMARY KEY,
    allowed  TEXT[] NOT NULL
);

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  -- Onboarding
  ('first_visit',            '{}', 'First app open ever'),
  ('onboarding_steps',       '{step_name,onboarding_index}', 'Continue on an onboarding step (question = slide title)'),
  ('onboarding_completed',   '{}', 'Onboarding finished'),
  -- Paywall
  ('subview',                '{trigger}', 'Paywall shown'),
  ('plan_choosing',          '{product_id,plan_type}', 'Plan switched on the paywall'),
  ('purchase_started',       '{product_id,trigger,plan_type,value,full_price}', 'Continue tapped'),
  ('purchase_cancelled',     '{product_id,trigger,plan_type}', 'System payment sheet cancelled'),
  ('purchase_failed',        '{error,product_id,trigger,plan_type}', 'Payment failed'),
  ('subpurchase',            '{product_id,trigger,plan_type,value,full_price}', 'Purchase succeeded'),
  ('remind_checkbox',        '{status}', 'Remind me before the trial ends toggled (reserved)'),
  ('paywall_cancel_click',   '{trigger}', 'Close tapped on a paywall'),
  ('special_offer_shown',    '{trigger}', 'Special offer / win-back screen shown'),
  ('restore_tapped',         '{}', 'Restore purchases'),
  -- In-app
  ('app_opened',             '{}', 'App became active on the main screen'),
  ('pro_feature_locked',     '{feature}', 'Free user tapped a Premium action'),
  ('scan_limit_reached',     '{scan_type,limit,used}', 'RESERVED: free scan limit (not sent yet)'),
  ('scan_started',           '{scan_type}', 'A scan/cleanup screen started analysing (photos, videos, contacts, calendar, compress)'),
  ('scan_completed',         '{scan_type,items}', 'Scan finished (items = found count, bytes = size)'),
  ('scan_failed',            '{scan_type,error}', 'Scan failed'),
  ('permission_result',      '{permission,status}', 'Photos / contacts / calendar permission answer'),
  ('cleanup_completed',      '{scan_type,items}', 'User deleted / merged / compressed items (items, bytes)'),
  ('fast_clean_completed',   '{}', 'Fast Clean finished'),
  ('charging_animation_selected','{animation}', 'Charging animation chosen'),
  ('charging_animation_shown','{source}', 'Charging animation opened (automation / deep_link / siri)'),
  ('widget_selected',        '{type}', 'Configurable widget type chosen in the app'),
  ('widget_installed',       '{kinds}', 'Widgets currently on the Home/Lock screen (daily)'),
  ('tab_bar_tapped',         '{tab}', 'Bottom tab bar'),
  ('support_opened',         '{}', 'Support page opened'),
  ('review_prompt_shown',    '{where}', 'App Store rating prompt'),
  ('att_answered',           '{status}', 'App Tracking Transparency answer'),
  ('attribution',            '{status}', 'AppsFlyer conversion data (fills user_attribution once)'),
  -- Tech
  ('api_error',              '{endpoint,http_status}', 'Network request error'),
  ('app_error',              '{where}', 'Handled error inside the app')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

INSERT INTO analytics.property_enums (property, allowed) VALUES
  ('trigger',   '{onboarding_flow,feature_gate,relaunch,setting,exit_offer,win_back}'),
  ('tab',       '{cleanup,widgets,charging,settings}'),
  ('scan_type', '{photos,screenshots,duplicates,videos,contacts,calendar,compress,fast_clean}')
ON CONFLICT (property) DO UPDATE SET allowed = EXCLUDED.allowed;

-- ───────────────────────── Partitions (TZ 2.1: created ahead of time) ─────────────────────────

CREATE OR REPLACE FUNCTION analytics.create_event_partitions(months_ahead INT DEFAULT 3)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    m DATE := date_trunc('month', now() - interval '1 month')::date;
    i INT;
    name TEXT;
BEGIN
    FOR i IN 0..months_ahead + 1 LOOP
        name := format('events_%s', to_char(m, 'YYYY_MM'));
        IF to_regclass('analytics.' || name) IS NULL THEN
            EXECUTE format('CREATE TABLE analytics.%I PARTITION OF analytics.events FOR VALUES FROM (%L) TO (%L)',
                           name, m, (m + interval '1 month')::date);
        END IF;
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;
SELECT analytics.create_event_partitions(3);

-- Retention (TZ 2.6): drop monthly partitions older than N months.
CREATE OR REPLACE FUNCTION analytics.drop_old_partitions(keep_months INT DEFAULT 18)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE r RECORD; n INT := 0; cutoff TEXT := to_char(date_trunc('month', now()) - make_interval(months => keep_months), 'YYYY_MM');
BEGIN
    FOR r IN SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
             WHERE i.inhparent = 'analytics.events'::regclass AND c.relname ~ '^events_\d{4}_\d{2}$'
               AND substring(c.relname from 8) < cutoff LOOP
        EXECUTE format('DROP TABLE analytics.%I', r.relname);
        n := n + 1;
    END LOOP;
    DELETE FROM analytics.events_rejected WHERE received_at < now() - interval '90 days';
    DELETE FROM analytics.webhook_log WHERE received_at < now() - interval '90 days';
    RETURN n;
END $$;

-- ───────────────────────── Sessions batch job (TZ 9.2) ─────────────────────────

CREATE OR REPLACE FUNCTION analytics.close_sessions()
RETURNS INT LANGUAGE sql AS $$
    WITH last_event AS (
        SELECT e.session_id, MAX(e.event_time) AS max_time
        FROM analytics.events e
        JOIN analytics.sessions s ON s.session_id = e.session_id AND s.ended_at IS NULL
        WHERE e.event_time > now() - interval '3 days'
        GROUP BY e.session_id
    ), upd AS (
        UPDATE analytics.sessions s
        SET ended_at = l.max_time,
            duration_seconds = GREATEST(0, EXTRACT(EPOCH FROM (l.max_time - s.started_at)))::INT
        FROM last_event l
        WHERE s.session_id = l.session_id
          AND s.ended_at IS NULL
          AND l.max_time < now() - interval '30 minutes'
        RETURNING 1
    )
    SELECT COUNT(*)::INT FROM upd;
$$;

-- ───────────────────────── Ingest (TZ 9.1, 9.5, 9.7) ─────────────────────────

CREATE OR REPLACE FUNCTION analytics.is_uuid(t TEXT) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
    SELECT t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

CREATE OR REPLACE FUNCTION analytics.try_ts(t TEXT) RETURNS TIMESTAMPTZ LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN t::timestamptz; EXCEPTION WHEN others THEN RETURN NULL; END $$;

CREATE OR REPLACE FUNCTION analytics.validate_event(e JSONB) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    req TEXT[];
    k TEXT;
    v TEXT;
    allowed TEXT[];
    props JSONB := COALESCE(e->'properties', '{}'::jsonb);
BEGIN
    IF jsonb_typeof(e) <> 'object' THEN RETURN 'not_an_object'; END IF;
    IF NOT analytics.is_uuid(e->>'event_id') THEN RETURN 'bad_event_id'; END IF;
    IF NOT analytics.is_uuid(e->>'session_id') THEN RETURN 'bad_session_id'; END IF;
    SELECT required INTO req FROM analytics.event_catalog WHERE event_name = e->>'event_name';
    IF NOT FOUND THEN RETURN 'unknown_event'; END IF;
    IF analytics.try_ts(e->>'event_time') IS NULL THEN RETURN 'bad_event_time'; END IF;
    IF jsonb_typeof(props) <> 'object' THEN RETURN 'bad_properties'; END IF;
    FOREACH k IN ARRAY req LOOP
        v := props->>k;
        IF v IS NULL OR v = '' THEN RETURN 'missing_' || k; END IF;
        SELECT pe.allowed INTO allowed FROM analytics.property_enums pe WHERE pe.property = k;
        IF FOUND AND NOT (v = ANY(allowed)) THEN RETURN 'bad_' || k; END IF;
    END LOOP;
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.analytics_ingest(payload JSONB, country TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    u JSONB := COALESCE(payload->'user', '{}'::jsonb);
    evs JSONB := COALESCE(payload->'events', '[]'::jsonb);
    metas JSONB := COALESCE(payload->'sessions', '{}'::jsonb);
    uid UUID;
    app_ver TEXT := left(COALESCE(u->>'app_version', 'unknown'), 32);
    plat TEXT := CASE WHEN u->>'platform' = 'android' THEN 'android' ELSE 'ios' END;
    e JSONB;
    reason TEXT;
    sid UUID;
    meta JSONB;
    n INT;
    premium BOOLEAN;
    accepted INT := 0;
    rejected INT := 0;
    entry TEXT;
    p JSONB;
BEGIN
    IF jsonb_typeof(evs) <> 'array' THEN evs := '[]'::jsonb; END IF;

    IF NOT analytics.is_uuid(u->>'user_id') THEN
        INSERT INTO events_rejected (event_id, session_id, event_name, event_time, properties, app_version, platform, rejection_reason)
        SELECT CASE WHEN analytics.is_uuid(x->>'event_id') THEN (x->>'event_id')::uuid END,
               CASE WHEN analytics.is_uuid(x->>'session_id') THEN (x->>'session_id')::uuid END,
               left(COALESCE(x->>'event_name', 'unknown'), 64), NULL, COALESCE(x->'properties', '{}'::jsonb),
               app_ver, plat, 'missing_user_id'
        FROM jsonb_array_elements(evs) x;
        RETURN jsonb_build_object('accepted', 0, 'rejected', jsonb_array_length(evs));
    END IF;
    uid := (u->>'user_id')::uuid;

    -- users (TZ 5.1)
    INSERT INTO users (user_id, anonymous_id, apple_id, adapty_profile_id, last_seen_at, first_seen_app_version, country, platform)
    VALUES (uid, uid, u->>'apple_id', u->>'adapty_profile_id', now(), app_ver, country, plat)
    ON CONFLICT (user_id) DO UPDATE SET
        last_seen_at = now(), updated_at = now(),
        country = COALESCE(EXCLUDED.country, users.country),
        apple_id = COALESCE(EXCLUDED.apple_id, users.apple_id),
        adapty_profile_id = COALESCE(EXCLUDED.adapty_profile_id, users.adapty_profile_id);

    SELECT is_active INTO premium FROM subscription_status WHERE user_id = uid;
    premium := COALESCE(premium, false);

    -- sessions: open on first event (TZ 9.1), number + re-engagement (TZ 9.5)
    FOR sid IN
        SELECT DISTINCT (x->>'session_id')::uuid FROM jsonb_array_elements(evs) x WHERE analytics.is_uuid(x->>'session_id')
    LOOP
        IF NOT EXISTS (SELECT 1 FROM sessions WHERE session_id = sid) THEN
            PERFORM pg_advisory_xact_lock(hashtext(uid::text));
            SELECT COALESCE(MAX(session_number), 0) + 1 INTO n FROM sessions WHERE user_id = uid;
            meta := COALESCE(metas->(sid::text), '{}'::jsonb);
            entry := meta->>'entry_source';
            INSERT INTO sessions (session_id, user_id, session_number, started_at, is_premium_at_start, app_version, platform,
                                  os_version, device_model, idfv, push_token, push_permission_granted, locale, timezone,
                                  country_code, entry_source, entry_utm_source, is_reengagement)
            SELECT sid, uid, n,
                   COALESCE((SELECT MIN((x->>'event_time')::timestamptz) FROM jsonb_array_elements(evs) x
                             WHERE x->>'session_id' = sid::text AND analytics.validate_event(x) IS NULL), now()),
                   premium, app_ver, plat,
                   u->>'os_version', u->>'device_model', u->>'idfv', u->>'push_token',
                   (u->>'push_permission_granted')::boolean, u->>'locale', u->>'timezone',
                   country, entry, meta->>'entry_utm_source',
                   n > 1 AND COALESCE(entry IN ('push', 'notification', 'deep_link'), false)
            ON CONFLICT (session_id) DO NOTHING;
        END IF;
    END LOOP;

    -- events (idempotent) / events_rejected (TZ 9.7)
    FOR e IN SELECT * FROM jsonb_array_elements(evs) LIMIT 500 LOOP
        reason := analytics.validate_event(e);
        IF reason IS NOT NULL THEN
            INSERT INTO events_rejected (event_id, user_id, session_id, event_name, event_time, properties, app_version, platform, rejection_reason)
            VALUES (CASE WHEN analytics.is_uuid(e->>'event_id') THEN (e->>'event_id')::uuid END, uid,
                    CASE WHEN analytics.is_uuid(e->>'session_id') THEN (e->>'session_id')::uuid END,
                    left(COALESCE(e->>'event_name', 'unknown'), 64),
                    analytics.try_ts(e->>'event_time'),
                    CASE WHEN jsonb_typeof(e->'properties') = 'object' THEN e->'properties' ELSE '{}'::jsonb END,
                    app_ver, plat, reason);
            rejected := rejected + 1;
            CONTINUE;
        END IF;
        p := COALESCE(e->'properties', '{}'::jsonb);
        INSERT INTO events (event_id, user_id, session_id, event_name, event_time, properties, app_version, platform)
        VALUES ((e->>'event_id')::uuid, uid, (e->>'session_id')::uuid, e->>'event_name', (e->>'event_time')::timestamptz,
                p, app_ver, plat)
        ON CONFLICT DO NOTHING;
        accepted := accepted + 1;

        -- AppsFlyer conversion data → user_attribution, once (TZ 9.4)
        IF e->>'event_name' = 'attribution' THEN
            INSERT INTO user_attribution (user_id, install_at, utm_source, campaign_id, campaign_name, adset_id, adset_name,
                                          ad_id, ad_name, attribution_source, is_organic)
            VALUES (uid, COALESCE(analytics.try_ts(p->>'install_time'), (e->>'event_time')::timestamptz),
                    p->>'media_source', p->>'campaign_id', p->>'campaign', p->>'adset_id', p->>'adset', p->>'ad_id', p->>'ad',
                    'appsflyer',
                    CASE WHEN lower(p->>'status') = 'organic' THEN 'organic'
                         WHEN COALESCE(p->>'media_source', '') <> '' THEN 'paid_attributed'
                         ELSE 'paid_unattributed' END)
            ON CONFLICT (user_id) DO NOTHING;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('accepted', accepted, 'rejected', rejected);
END $$;

-- ───────────────────────── Adapty webhook (TZ 5.5–5.7, 9.3, 9.6) ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_adapty_webhook(body JSONB)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    t TEXT := body->>'event_type';
    p JSONB := COALESCE(body->'event_properties', '{}'::jsonb);
    customer TEXT := lower(COALESCE(body->>'customer_user_id', ''));
    uid UUID;
    product TEXT;
    orig TEXT;
    occurred TIMESTAMPTZ;
    ptype TEXT;
    pay_id UUID;
    st TEXT;
    active BOOLEAN;
    renew BOOLEAN;
BEGIN
    IF t IS NULL THEN RETURN 'ping'; END IF;

    IF analytics.is_uuid(customer) THEN
        SELECT user_id INTO uid FROM users WHERE user_id = customer::uuid;
    END IF;
    IF uid IS NULL THEN
        -- TZ 9.3: never create a user silently
        INSERT INTO integration_anomalies (kind, details, raw_payload)
        VALUES (CASE WHEN customer = '' THEN 'missing_customer_user_id' ELSE 'unknown_customer_user_id' END,
                format('%s profile=%s customer=%s', t, COALESCE(body->>'profile_id', '-'), COALESCE(NULLIF(customer, ''), '-')), body);
        INSERT INTO webhook_log (source, event_type, status) VALUES ('adapty', t, 'anomaly');
        RETURN 'anomaly';
    END IF;

    IF body->>'profile_id' IS NOT NULL THEN
        UPDATE users SET adapty_profile_id = COALESCE(adapty_profile_id, body->>'profile_id') WHERE user_id = uid;
    END IF;

    product := COALESCE(p->>'vendor_product_id', p->>'product_id', 'unknown');
    orig := COALESCE(p->>'original_transaction_id', p->>'transaction_id', 'unknown');
    occurred := COALESCE(analytics.try_ts(p->>'event_datetime'), analytics.try_ts(body->>'event_datetime'), now());

    -- payments: append-only, dedup by transaction_id
    ptype := CASE t
        WHEN 'trial_started' THEN 'trial_start'
        WHEN 'trial_converted' THEN 'trial_converted'
        WHEN 'subscription_started' THEN 'initial_purchase'
        WHEN 'subscription_initial_purchase' THEN 'initial_purchase'
        WHEN 'subscription_renewed' THEN 'renewal'
        WHEN 'billing_issue_detected' THEN 'billing_retry'
        WHEN 'non_subscription_purchase' THEN 'one_time_purchase'
    END;
    IF ptype IS NOT NULL AND COALESCE(p->>'transaction_id', '') <> '' THEN
        INSERT INTO payments (transaction_id, user_id, product_id, event_type, is_recurring, amount_usd, proceeds_usd, currency,
                              original_transaction_id, occurred_at, is_trial, environment, raw_payload)
        VALUES (p->>'transaction_id', uid, product, ptype, ptype <> 'one_time_purchase',
                CASE WHEN ptype = 'trial_start' THEN 0 ELSE NULLIF(p->>'price_usd', '')::numeric END,
                CASE WHEN ptype = 'trial_start' THEN 0 ELSE NULLIF(p->>'proceeds_usd', '')::numeric END,
                p->>'currency', orig, occurred, ptype = 'trial_start', p->>'environment', body)
        ON CONFLICT (transaction_id) DO NOTHING;
    END IF;

    -- refunds: one per transaction
    IF t IN ('subscription_refunded', 'non_subscription_purchase_refunded', 'trial_refunded') THEN
        SELECT payment_id INTO pay_id FROM payments WHERE transaction_id = p->>'transaction_id';
        IF pay_id IS NULL THEN
            INSERT INTO integration_anomalies (kind, details, raw_payload)
            VALUES ('refund_without_payment', format('%s txn=%s', t, COALESCE(p->>'transaction_id', '-')), body);
        ELSE
            INSERT INTO refunds (payment_id, status, amount_usd, reason, requested_at, processed_at, raw_payload)
            VALUES (pay_id, 'processed', NULLIF(p->>'price_usd', '')::numeric,
                    COALESCE(p->>'cancellation_reason', p->>'refund_reason'), occurred, occurred, body)
            ON CONFLICT (payment_id) DO UPDATE SET status = 'processed', processed_at = EXCLUDED.processed_at, raw_payload = EXCLUDED.raw_payload;
        END IF;
    END IF;

    -- subscription_status: access_level_updated is the source of truth (upsert)
    IF t = 'access_level_updated' THEN
        active := COALESCE((p->>'is_active')::boolean, false);
        renew := COALESCE((p->>'will_renew')::boolean, false);
        st := CASE
            WHEN NOT active THEN 'expired'
            WHEN COALESCE(p->>'billing_issue_detected_at', '') <> '' THEN 'billing_issue'
            WHEN COALESCE((p->>'is_in_grace_period')::boolean, false) THEN 'in_grace_period'
            WHEN p->>'active_introductory_offer_type' = 'free_trial' THEN 'trial'
            WHEN NOT renew THEN 'cancelled'
            ELSE 'active' END;
        INSERT INTO subscription_status (user_id, original_transaction_id, product_id, current_status, is_active, will_renew,
                                         expires_at, cancel_date, cancellation_reason, raw_payload, updated_at)
        VALUES (uid, orig, product, st, active, renew, analytics.try_ts(p->>'expires_at'),
                analytics.try_ts(p->>'unsubscribed_at'), p->>'cancellation_reason', body, now())
        ON CONFLICT (user_id) DO UPDATE SET
            original_transaction_id = EXCLUDED.original_transaction_id, product_id = EXCLUDED.product_id,
            current_status = EXCLUDED.current_status, is_active = EXCLUDED.is_active, will_renew = EXCLUDED.will_renew,
            expires_at = EXCLUDED.expires_at,
            cancel_date = CASE WHEN EXCLUDED.will_renew THEN NULL ELSE COALESCE(EXCLUDED.cancel_date, subscription_status.cancel_date) END,
            cancellation_reason = COALESCE(EXCLUDED.cancellation_reason, subscription_status.cancellation_reason),
            raw_payload = EXCLUDED.raw_payload, updated_at = now();
    ELSIF t IN ('subscription_renewal_cancelled', 'trial_renewal_cancelled') THEN
        UPDATE subscription_status SET current_status = 'cancelled', will_renew = false, cancel_date = occurred,
               cancellation_reason = COALESCE(p->>'cancellation_reason', cancellation_reason), updated_at = now()
        WHERE user_id = uid;
    ELSIF t IN ('subscription_renewal_reactivated', 'trial_renewal_reactivated') THEN
        UPDATE subscription_status SET current_status = CASE WHEN t LIKE 'trial%' THEN 'trial' ELSE 'active' END,
               will_renew = true, cancel_date = NULL, updated_at = now() WHERE user_id = uid;
    ELSIF t IN ('subscription_expired', 'trial_expired') THEN
        UPDATE subscription_status SET current_status = 'expired', is_active = false, will_renew = false, updated_at = now() WHERE user_id = uid;
    ELSIF t = 'entered_grace_period' THEN
        UPDATE subscription_status SET current_status = 'in_grace_period', updated_at = now() WHERE user_id = uid;
    ELSIF t = 'billing_issue_detected' THEN
        UPDATE subscription_status SET current_status = 'billing_issue', updated_at = now() WHERE user_id = uid;
    ELSIF t = 'subscription_paused' THEN
        UPDATE subscription_status SET current_status = 'paused', is_active = false, updated_at = now() WHERE user_id = uid;
    END IF;

    INSERT INTO webhook_log (source, event_type, status) VALUES ('adapty', t, 'ok');
    RETURN 'ok';
END $$;

-- Worker logs webhook processing errors here (the failed transaction rolled back everything else).
CREATE OR REPLACE FUNCTION public.analytics_log_webhook_error(event_type TEXT, error TEXT)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = analytics, public AS $$
    INSERT INTO webhook_log (source, event_type, status, error) VALUES ('adapty', event_type, 'error', left(error, 2000));
$$;

-- ───────────────────────── Ad spend import ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_upsert_ad_spend(rows_json JSONB)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE n INT;
BEGIN
    INSERT INTO ad_spend (date, source, campaign_id, campaign_name, adset_id, adset_name, spend_usd, impressions, clicks, installs, updated_at)
    SELECT (r->>'date')::date, lower(r->>'source'), COALESCE(r->>'campaign_id', ''), NULLIF(r->>'campaign_name', ''),
           COALESCE(r->>'adset_id', ''), NULLIF(r->>'adset_name', ''), (r->>'spend_usd')::numeric,
           NULLIF(r->>'impressions', '')::int, NULLIF(r->>'clicks', '')::int, NULLIF(r->>'installs', '')::int, now()
    FROM jsonb_array_elements(rows_json) r
    WHERE r->>'date' IS NOT NULL AND r->>'source' IS NOT NULL AND (r->>'spend_usd') ~ '^-?[0-9]+(\.[0-9]+)?$'
    ON CONFLICT (date, source, campaign_id, adset_id) DO UPDATE SET
        campaign_name = EXCLUDED.campaign_name, adset_name = EXCLUDED.adset_name, spend_usd = EXCLUDED.spend_usd,
        impressions = EXCLUDED.impressions, clicks = EXCLUDED.clicks, installs = EXCLUDED.installs, updated_at = now();
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- ───────────────────────── Reports (dashboard /admin) — no PII returned ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_report(name TEXT, days INT DEFAULT 30)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    since TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(days, 730)));
    res JSONB;
BEGIN
    CASE name
    WHEN 'overview' THEN
        SELECT jsonb_build_array(jsonb_build_object(
            'new_users', (SELECT COUNT(*) FROM users WHERE created_at >= since),
            'dau', (SELECT COUNT(DISTINCT user_id) FROM events WHERE event_time >= now() - interval '1 day'),
            'events', (SELECT COUNT(*) FROM events WHERE received_at >= since),
            'active_subscriptions', (SELECT COUNT(*) FROM subscription_status WHERE is_active),
            'active_trials', (SELECT COUNT(*) FROM subscription_status WHERE is_active AND current_status = 'trial'),
            'revenue_usd', (SELECT COALESCE(SUM(amount_usd), 0) FROM payments WHERE NOT is_trial AND occurred_at >= since
                            AND COALESCE(environment, '') <> 'Sandbox'),
            'refunds_usd', (SELECT COALESCE(SUM(amount_usd), 0) FROM refunds WHERE requested_at >= since))) INTO res;

    WHEN 'mrr' THEN
        WITH last_paid AS (
            SELECT DISTINCT ON (user_id) user_id, product_id, amount_usd
            FROM payments WHERE NOT is_trial AND amount_usd > 0 AND COALESCE(environment, '') <> 'Sandbox'
            ORDER BY user_id, occurred_at DESC)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.mrr_usd DESC), '[]') INTO res FROM (
            SELECT s.product_id, COUNT(*) AS subscribers,
                   ROUND(SUM(CASE WHEN lp.product_id ILIKE '%year%' THEN lp.amount_usd / 12
                                  WHEN lp.product_id ILIKE '%week%' THEN lp.amount_usd * 52 / 12
                                  ELSE lp.amount_usd END), 2) AS mrr_usd
            FROM subscription_status s JOIN last_paid lp ON lp.user_id = s.user_id
            WHERE s.is_active AND s.current_status <> 'trial'
            GROUP BY s.product_id) r;

    WHEN 'revenue_by_trigger' THEN
        WITH buyer_trigger AS (
            SELECT DISTINCT ON (user_id) user_id, properties->>'trigger' AS trigger
            FROM events WHERE event_name = 'subpurchase' ORDER BY user_id, event_time)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.revenue_usd DESC), '[]') INTO res FROM (
            SELECT COALESCE(bt.trigger, 'unknown') AS trigger, COUNT(DISTINCT p.user_id) AS payers,
                   ROUND(SUM(p.amount_usd), 2) AS revenue_usd,
                   ROUND(SUM(CASE WHEN p.product_id ILIKE '%year%' THEN p.amount_usd / 12 ELSE p.amount_usd END), 2) AS new_mrr_usd
            FROM payments p LEFT JOIN buyer_trigger bt ON bt.user_id = p.user_id
            WHERE NOT p.is_trial AND p.occurred_at >= since AND COALESCE(p.environment, '') <> 'Sandbox'
            GROUP BY 1) r;

    WHEN 'paywall_funnel' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.viewers DESC), '[]') INTO res FROM (
            SELECT properties->>'trigger' AS trigger,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subview') AS viewers,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_started') AS started,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subpurchase') AS purchased,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'paywall_cancel_click') AS cancelled,
                   ROUND(100.0 * COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subpurchase')
                         / NULLIF(COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subview'), 0), 2) AS cr_pct
            FROM events
            WHERE event_name IN ('subview', 'purchase_started', 'subpurchase', 'paywall_cancel_click') AND event_time >= since
            GROUP BY 1) r;

    WHEN 'feature_gates' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT properties->>'feature' AS feature, event_name, COUNT(*) AS hits, COUNT(DISTINCT user_id) AS users
            FROM events WHERE event_name IN ('pro_feature_locked', 'free_limit_reached') AND event_time >= since
            GROUP BY 1, 2) r;

    WHEN 'onboarding_funnel' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.idx), '[]') INTO res FROM (
            SELECT (properties->>'onboarding_index')::int AS idx, properties->>'step_name' AS step, COUNT(DISTINCT user_id) AS users
            FROM events WHERE event_name = 'onboarding_steps' AND event_time >= since
            GROUP BY 1, 2) r;

    WHEN 'feature_usage' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT event_name, COUNT(*) AS events, COUNT(DISTINCT user_id) AS users
            FROM events WHERE event_time >= since AND event_name IN
              ('scan_completed', 'cleanup_completed', 'fast_clean_completed', 'charging_animation_selected',
               'charging_animation_shown', 'widget_selected', 'widget_installed', 'tab_bar_tapped', 'review_prompt_shown')
            GROUP BY 1) r;

    WHEN 'cac' THEN
        WITH spend AS (
            SELECT source, campaign_id, MAX(campaign_name) AS campaign_name, SUM(spend_usd) AS spend
            FROM ad_spend WHERE date >= since::date GROUP BY 1, 2),
        inst AS (
            SELECT utm_source AS source, COALESCE(campaign_id, '') AS campaign_id, COUNT(*) AS installs
            FROM user_attribution WHERE install_at >= since GROUP BY 1, 2),
        pay AS (
            SELECT a.utm_source AS source, COALESCE(a.campaign_id, '') AS campaign_id,
                   COUNT(DISTINCT p.user_id) AS payers, SUM(p.amount_usd) AS revenue
            FROM payments p JOIN user_attribution a ON a.user_id = p.user_id
            WHERE NOT p.is_trial AND a.install_at >= since AND COALESCE(p.environment, '') <> 'Sandbox' GROUP BY 1, 2)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.spend_usd DESC), '[]') INTO res FROM (
            SELECT s.source, s.campaign_id, s.campaign_name, ROUND(s.spend, 2) AS spend_usd,
                   COALESCE(i.installs, 0) AS installs, COALESCE(pay.payers, 0) AS payers,
                   ROUND(s.spend / NULLIF(i.installs, 0), 2) AS cpi_usd,
                   ROUND(s.spend / NULLIF(pay.payers, 0), 2) AS cac_usd,
                   ROUND(COALESCE(pay.revenue, 0), 2) AS revenue_usd,
                   ROUND(100.0 * COALESCE(pay.revenue, 0) / NULLIF(s.spend, 0), 1) AS roas_pct
            FROM spend s
            LEFT JOIN inst i ON i.source = s.source AND i.campaign_id = s.campaign_id
            LEFT JOIN pay ON pay.source = s.source AND pay.campaign_id = s.campaign_id) r;

    WHEN 'sources' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT COALESCE(a.utm_source, 'no_attribution') AS source, COALESCE(a.is_organic, '-') AS type, COUNT(*) AS users
            FROM users u LEFT JOIN user_attribution a ON a.user_id = u.user_id
            WHERE u.created_at >= since GROUP BY 1, 2) r;

    WHEN 'plans' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.picks DESC), '[]') INTO res FROM (
            SELECT properties->>'product_id' AS product_id, properties->>'plan_type' AS plan_type,
                   COUNT(*) FILTER (WHERE event_name = 'plan_choosing') AS picks,
                   COUNT(*) FILTER (WHERE event_name = 'purchase_started') AS started,
                   COUNT(*) FILTER (WHERE event_name = 'subpurchase') AS purchased
            FROM events WHERE event_name IN ('plan_choosing', 'purchase_started', 'subpurchase') AND event_time >= since
            GROUP BY 1, 2) r;

    WHEN 'cleanup' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT properties->>'scan_type' AS scan_type,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'scan_completed') AS users_scanned,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'cleanup_completed') AS users,
                   SUM(COALESCE((properties->>'items')::numeric, 0)) FILTER (WHERE event_name = 'cleanup_completed') AS items_cleaned,
                   ROUND(SUM(COALESCE((properties->>'bytes')::numeric, 0)) FILTER (WHERE event_name = 'cleanup_completed') / 1e9, 2) AS gb_freed
            FROM events WHERE event_name IN ('scan_completed', 'cleanup_completed') AND event_time >= since
              AND COALESCE(properties->>'items', '0') ~ '^[0-9]+$' AND COALESCE(properties->>'bytes', '0') ~ '^[0-9]+$'
            GROUP BY 1) r;

    WHEN 'rejected' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.n DESC), '[]') INTO res FROM (
            SELECT event_name, rejection_reason, app_version, COUNT(*) AS n
            FROM events_rejected WHERE received_at >= since GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 100) r;

    WHEN 'health' THEN
        SELECT jsonb_build_array(jsonb_build_object(
            'events_last_hour', (SELECT COUNT(*) FROM events WHERE received_at >= now() - interval '1 hour'),
            'events_last_day', (SELECT COUNT(*) FROM events WHERE received_at >= now() - interval '1 day'),
            'rejected_last_hour', (SELECT COUNT(*) FROM events_rejected WHERE received_at >= now() - interval '1 hour'),
            'webhook_errors_last_hour', (SELECT COUNT(*) FROM webhook_log WHERE status = 'error' AND received_at >= now() - interval '1 hour'),
            'webhook_errors_24h', (SELECT COUNT(*) FROM webhook_log WHERE status = 'error' AND received_at >= now() - interval '1 day'),
            'webhooks_24h', (SELECT COUNT(*) FROM webhook_log WHERE received_at >= now() - interval '1 day'),
            'anomalies_last_hour', (SELECT COUNT(*) FROM integration_anomalies WHERE created_at >= now() - interval '1 hour'),
            'anomalies_24h', (SELECT COUNT(*) FROM integration_anomalies WHERE created_at >= now() - interval '1 day'),
            'open_sessions', (SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL))) INTO res;

    WHEN 'anomalies' THEN
        SELECT COALESCE(jsonb_agg(r), '[]') INTO res FROM (
            SELECT created_at, kind, details FROM integration_anomalies ORDER BY id DESC LIMIT 100) r;

    ELSE
        RAISE EXCEPTION 'unknown report %', name USING ERRCODE = '22023';
    END CASE;
    RETURN res;
END $$;

-- Cron entry point used by the Worker when pg_cron is not available.
CREATE OR REPLACE FUNCTION public.analytics_maintenance()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE closed INT;
BEGIN
    closed := analytics.close_sessions();
    PERFORM analytics.create_event_partitions(3);
    IF extract(hour FROM now()) = 3 AND extract(minute FROM now()) < 15 THEN
        PERFORM analytics.drop_old_partitions(18);
    END IF;
    RETURN jsonb_build_object('closed_sessions', closed);
END $$;

-- ───────────────────────── Permissions ─────────────────────────

REVOKE ALL ON SCHEMA analytics FROM PUBLIC;
DO $$
DECLARE f TEXT;
BEGIN
    FOREACH f IN ARRAY ARRAY[
        'public.analytics_ingest(jsonb, text)', 'public.analytics_adapty_webhook(jsonb)',
        'public.analytics_log_webhook_error(text, text)', 'public.analytics_upsert_ad_spend(jsonb)',
        'public.analytics_report(text, integer)', 'public.analytics_maintenance()'] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
            EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon, authenticated', f);
        END IF;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
        END IF;
    END LOOP;
END $$;

-- BI read-only role (TZ 2.6): no raw_payload, no apple_id / idfv / push_token.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bi_readonly') THEN CREATE ROLE bi_readonly NOLOGIN; END IF;
END $$;
GRANT USAGE ON SCHEMA analytics TO bi_readonly;
GRANT SELECT ON analytics.user_attribution, analytics.events, analytics.events_rejected, analytics.ad_spend,
                analytics.event_catalog TO bi_readonly;
GRANT SELECT (user_id, created_at, last_seen_at, first_seen_app_version, country, platform) ON analytics.users TO bi_readonly;
GRANT SELECT (session_id, user_id, session_number, started_at, ended_at, duration_seconds, is_premium_at_start, app_version,
              platform, os_version, device_model, locale, timezone, country_code, entry_source, entry_utm_source, is_reengagement)
      ON analytics.sessions TO bi_readonly;
GRANT SELECT (payment_id, transaction_id, user_id, product_id, event_type, is_recurring, amount_usd, proceeds_usd, currency,
              original_transaction_id, occurred_at, is_trial, environment) ON analytics.payments TO bi_readonly;
GRANT SELECT (user_id, original_transaction_id, product_id, current_status, is_active, will_renew, expires_at, cancel_date,
              cancellation_reason, updated_at) ON analytics.subscription_status TO bi_readonly;
GRANT SELECT (refund_id, payment_id, status, amount_usd, reason, requested_at, processed_at) ON analytics.refunds TO bi_readonly;
-- To use it (e.g. Metabase): CREATE ROLE metabase LOGIN PASSWORD '…' IN ROLE bi_readonly;

-- ───────────────────────── pg_cron (Supabase: Database → Extensions → pg_cron) ─────────────────────────
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE 'analytics_%';
        PERFORM cron.schedule('analytics_close_sessions', '*/15 * * * *', 'SELECT analytics.close_sessions()');
        PERFORM cron.schedule('analytics_partitions', '0 2 * * *', 'SELECT analytics.create_event_partitions(3)');
        PERFORM cron.schedule('analytics_retention', '30 3 * * *', 'SELECT analytics.drop_old_partitions(18)');
    END IF;
EXCEPTION WHEN others THEN
    RAISE NOTICE 'pg_cron not configured (%). The Worker cron calls analytics_maintenance() instead.', SQLERRM;
END $$;
-- X Clean — growth analytics for /admin (organic vs paid, funnels, cohorts, LTV, retention, insights data).
-- Run after 0001_init.sql (Supabase → SQL Editor, or the CI workflow). Idempotent: safe to run again.
--
-- Entry point: public.analytics_growth(p_name, p_days, p_segment, p_country)
--   country: ISO code ('US', 'DE', …) or NULL/'' for all countries ('??' = unknown country)
--   segment: 'all' | 'organic' | 'paid' | 'unknown'
--     organic = AppsFlyer says Organic (App Store search/browse, word of mouth, web)
--     paid    = AppsFlyer attributed the install to a media source / campaign
--     unknown = no attribution event received from the app yet
--   Sandbox purchases are always excluded. No PII is returned.

-- ───────────────────────── Helpers ─────────────────────────

-- Older signatures (before the country filter) — dropped so calls are not ambiguous.
DROP FUNCTION IF EXISTS public.analytics_growth(TEXT, INT, TEXT);
DROP FUNCTION IF EXISTS analytics.growth_kpis(TIMESTAMPTZ, TIMESTAMPTZ, TEXT);
DROP FUNCTION IF EXISTS analytics.seg_users(TEXT);

-- One row per user with its acquisition segment. Inlined by the planner (LANGUAGE sql STABLE).
CREATE OR REPLACE FUNCTION analytics.seg_users(seg TEXT, ctry TEXT DEFAULT NULL)
RETURNS TABLE (user_id UUID, created_at TIMESTAMPTZ, country TEXT, app_version TEXT,
               segment TEXT, media_source TEXT, campaign_id TEXT, campaign_name TEXT)
LANGUAGE sql STABLE AS $$
    SELECT u.user_id, u.created_at, COALESCE(u.country, '??'), u.first_seen_app_version,
           CASE WHEN a.user_id IS NULL THEN 'unknown' WHEN a.is_organic = 'organic' THEN 'organic' ELSE 'paid' END,
           CASE WHEN a.user_id IS NULL THEN 'unknown' WHEN a.is_organic = 'organic' THEN 'organic'
                ELSE COALESCE(NULLIF(a.utm_source, ''), 'paid_unknown') END,
           COALESCE(a.campaign_id, ''), a.campaign_name
    FROM analytics.users u
    LEFT JOIN analytics.user_attribution a ON a.user_id = u.user_id
    WHERE (seg = 'all'
           OR (seg = 'organic' AND a.is_organic = 'organic')
           OR (seg = 'paid' AND a.is_organic IN ('paid_attributed', 'paid_unattributed'))
           OR (seg = 'unknown' AND a.user_id IS NULL))
      AND (ctry IS NULL OR COALESCE(u.country, '??') = ctry)
$$;

-- Real (non-sandbox) payments.
CREATE OR REPLACE VIEW analytics.v_pay AS
    SELECT p.*, (r.payment_id IS NOT NULL) AS refunded, COALESCE(r.amount_usd, 0) AS refund_usd
    FROM analytics.payments p
    LEFT JOIN analytics.refunds r ON r.payment_id = p.payment_id
    WHERE COALESCE(p.environment, '') <> 'Sandbox';

-- Monthly value of a subscription price (for MRR).
CREATE OR REPLACE FUNCTION analytics.monthly(product TEXT, amount NUMERIC) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN product ILIKE '%year%' THEN amount / 12
                WHEN product ILIKE '%week%' THEN amount * 52 / 12
                ELSE amount END
$$;

-- KPIs for one window [t0, t1) — used for the current and the previous period.
CREATE OR REPLACE FUNCTION analytics.growth_kpis(t0 TIMESTAMPTZ, t1 TIMESTAMPTZ, seg TEXT, ctry TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE sql STABLE AS $$
WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
cohort AS (SELECT * FROM su WHERE created_at >= t0 AND created_at < t1),
pay AS (SELECT p.* FROM analytics.v_pay p JOIN su USING (user_id) WHERE p.occurred_at >= t0 AND p.occurred_at < t1),
first_conv AS (   -- first trial / paid start of each cohort user, any time
    SELECT p.user_id, MIN(p.occurred_at) FILTER (WHERE p.is_trial) AS first_trial,
           MIN(p.occurred_at) FILTER (WHERE NOT p.is_trial AND p.amount_usd > 0) AS first_paid
    FROM analytics.v_pay p JOIN cohort c USING (user_id) GROUP BY 1),
trials AS (        -- trials that started in the window and had time to end (3-day trial + 1 day of retries)
    SELECT p.original_transaction_id, p.user_id FROM pay p
    WHERE p.event_type = 'trial_start' AND p.occurred_at < now() - interval '4 days'),
pw AS (SELECT DISTINCT e.user_id FROM analytics.events e JOIN su USING (user_id)
       WHERE e.event_name = 'subview' AND e.event_time >= t0 AND e.event_time < t1)
SELECT jsonb_build_object(
    'installs',            (SELECT COUNT(*) FROM cohort),
    'organic_installs',    (SELECT COUNT(*) FROM cohort WHERE segment = 'organic'),
    'paid_installs',       (SELECT COUNT(*) FROM cohort WHERE segment = 'paid'),
    'unknown_installs',    (SELECT COUNT(*) FROM cohort WHERE segment = 'unknown'),
    'paywall_viewers',     (SELECT COUNT(*) FROM pw),
    'trials',              (SELECT COUNT(*) FROM pay WHERE event_type = 'trial_start'),
    'new_paid',            (SELECT COUNT(*) FROM pay WHERE event_type IN ('initial_purchase', 'trial_converted')),
    'direct_purchases',    (SELECT COUNT(*) FROM pay WHERE event_type = 'initial_purchase'),
    'trial_conversions',   (SELECT COUNT(*) FROM pay WHERE event_type = 'trial_converted'),
    'renewals',            (SELECT COUNT(*) FROM pay WHERE event_type = 'renewal'),
    'payers',              (SELECT COUNT(DISTINCT user_id) FROM pay WHERE NOT is_trial AND amount_usd > 0),
    'revenue_usd',         (SELECT COALESCE(ROUND(SUM(amount_usd), 2), 0) FROM pay WHERE NOT is_trial),
    'proceeds_usd',        (SELECT COALESCE(ROUND(SUM(COALESCE(proceeds_usd, amount_usd * 0.7)), 2), 0) FROM pay WHERE NOT is_trial),
    'refunds',             (SELECT COUNT(*) FROM pay WHERE refunded),
    'refunds_usd',         (SELECT COALESCE(ROUND(SUM(refund_usd), 2), 0) FROM pay WHERE refunded),
    'refund_rate_pct',     (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE refunded) / NULLIF(COUNT(*), 0), 1)
                            FROM pay WHERE NOT is_trial AND amount_usd > 0),
    'install_to_paywall_pct', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (
                                   SELECT 1 FROM analytics.events e WHERE e.user_id = cohort.user_id AND e.event_name = 'subview'
                                     AND e.event_time >= cohort.created_at)) / NULLIF(COUNT(*), 0), 1) FROM cohort),
    'install_to_trial_pct',  (SELECT ROUND(100.0 * COUNT(first_trial) / NULLIF((SELECT COUNT(*) FROM cohort), 0), 2) FROM first_conv),
    'install_to_paid_pct',   (SELECT ROUND(100.0 * COUNT(first_paid) / NULLIF((SELECT COUNT(*) FROM cohort), 0), 2) FROM first_conv),
    'install_to_any_pct',    (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE first_trial IS NOT NULL OR first_paid IS NOT NULL)
                                   / NULLIF((SELECT COUNT(*) FROM cohort), 0), 2) FROM first_conv),
    'trials_matured',      (SELECT COUNT(*) FROM trials),
    'trial_to_paid_pct',   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (
                                SELECT 1 FROM analytics.v_pay x WHERE x.original_transaction_id = t.original_transaction_id
                                  AND NOT x.is_trial AND x.amount_usd > 0)) / NULLIF(COUNT(*), 0), 1) FROM trials t),
    'arpu_usd',            (SELECT ROUND(COALESCE(SUM(amount_usd), 0) / NULLIF((SELECT COUNT(*) FROM cohort), 0), 3)
                            FROM pay WHERE NOT is_trial),
    'arppu_usd',           (SELECT ROUND(SUM(amount_usd) / NULLIF(COUNT(DISTINCT user_id), 0), 2)
                            FROM pay WHERE NOT is_trial AND amount_usd > 0),
    'cohort_revenue_usd',  (SELECT COALESCE(ROUND(SUM(p.amount_usd), 2), 0) FROM analytics.v_pay p JOIN cohort USING (user_id)
                            WHERE NOT p.is_trial),
    'spend_usd',           (SELECT COALESCE(ROUND(SUM(spend_usd), 2), 0) FROM analytics.ad_spend
                            WHERE date >= t0::date AND date < t1::date AND seg IN ('all', 'paid') AND ctry IS NULL)
)
$$;

-- ───────────────────────── Reports ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_growth(p_name TEXT, p_days INT DEFAULT 30, p_segment TEXT DEFAULT 'all', p_country TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    d INT := GREATEST(1, LEAST(COALESCE(p_days, 30), 730));
    t1 TIMESTAMPTZ := now();
    t0 TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    seg TEXT := CASE WHEN p_segment IN ('organic', 'paid', 'unknown') THEN p_segment ELSE 'all' END;
    ctry TEXT := CASE WHEN upper(p_country) ~ '^([A-Z]{2}|\?\?)$' THEN upper(p_country) END;
    res JSONB;
BEGIN
    CASE p_name

    -- KPI cards with the previous period of the same length + snapshot of the subscriber base.
    WHEN 'kpis' THEN
        SELECT jsonb_build_object(
            'current', analytics.growth_kpis(t0, t1, seg, ctry),
            'previous', analytics.growth_kpis(t0 - make_interval(days => d), t0, seg, ctry),
            'snapshot', (
                WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
                last_paid AS (
                    SELECT DISTINCT ON (p.user_id) p.user_id, p.product_id, p.amount_usd
                    FROM analytics.v_pay p JOIN su USING (user_id)
                    WHERE NOT p.is_trial AND p.amount_usd > 0 ORDER BY p.user_id, p.occurred_at DESC)
                SELECT jsonb_build_object(
                    'active_paid',   COUNT(*) FILTER (WHERE s.is_active AND s.current_status <> 'trial'),
                    'active_trials', COUNT(*) FILTER (WHERE s.is_active AND s.current_status = 'trial'),
                    'auto_renew_off', COUNT(*) FILTER (WHERE s.is_active AND NOT s.will_renew),
                    'billing_issues', COUNT(*) FILTER (WHERE s.current_status IN ('billing_issue', 'in_grace_period')),
                    'mrr_usd', ROUND(COALESCE(SUM(analytics.monthly(lp.product_id, lp.amount_usd))
                                     FILTER (WHERE s.is_active AND s.current_status <> 'trial'), 0), 2))
                FROM analytics.subscription_status s JOIN su USING (user_id)
                LEFT JOIN last_paid lp ON lp.user_id = s.user_id)
        ) INTO res;

    -- One row per day: installs by segment, trials, new paid subs, revenue.
    WHEN 'daily' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        dd AS (SELECT generate_series(date_trunc('day', t0), date_trunc('day', t1), interval '1 day')::date AS day),
        inst AS (SELECT created_at::date AS day,
                        COUNT(*) FILTER (WHERE segment = 'organic') AS organic,
                        COUNT(*) FILTER (WHERE segment = 'paid') AS paid,
                        COUNT(*) FILTER (WHERE segment = 'unknown') AS unknown
                 FROM su WHERE created_at >= t0 GROUP BY 1),
        pay AS (SELECT p.occurred_at::date AS day,
                       COUNT(*) FILTER (WHERE p.event_type = 'trial_start') AS trials,
                       COUNT(*) FILTER (WHERE p.event_type IN ('initial_purchase', 'trial_converted')) AS new_paid,
                       COUNT(*) FILTER (WHERE p.event_type = 'renewal') AS renewals,
                       COALESCE(SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial), 0) AS revenue,
                       COALESCE(SUM(COALESCE(p.proceeds_usd, p.amount_usd * 0.7)) FILTER (WHERE NOT p.is_trial), 0) AS proceeds
                FROM analytics.v_pay p JOIN su USING (user_id) WHERE p.occurred_at >= t0 GROUP BY 1)
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'day', dd.day,
                   'installs', COALESCE(i.organic, 0) + COALESCE(i.paid, 0) + COALESCE(i.unknown, 0),
                   'organic', COALESCE(i.organic, 0), 'paid', COALESCE(i.paid, 0), 'unknown', COALESCE(i.unknown, 0),
                   'trials', COALESCE(p.trials, 0), 'new_paid', COALESCE(p.new_paid, 0), 'renewals', COALESCE(p.renewals, 0),
                   'revenue_usd', ROUND(COALESCE(p.revenue, 0), 2), 'proceeds_usd', ROUND(COALESCE(p.proceeds, 0), 2))
                 ORDER BY dd.day), '[]')
        INTO res
        FROM dd LEFT JOIN inst i ON i.day = dd.day LEFT JOIN pay p ON p.day = dd.day;

    -- Install cohort funnel: what share of users who installed in the period reached each step (any time later).
    WHEN 'funnel' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        ev AS (SELECT e.user_id,
                      bool_or(e.event_name = 'onboarding_completed') AS onb,
                      bool_or(e.event_name = 'subview') AS pw,
                      bool_or(e.event_name = 'plan_choosing') AS plan,
                      bool_or(e.event_name = 'purchase_started') AS started,
                      bool_or(e.event_name = 'special_offer_shown') AS offer,
                      bool_or(e.event_name IN ('scan_completed', 'cleanup_completed', 'fast_clean_completed')) AS used
               FROM analytics.events e JOIN cohort c USING (user_id)
               WHERE e.event_time >= c.created_at - interval '1 hour'
                 AND e.event_name IN ('onboarding_completed', 'subview', 'plan_choosing', 'purchase_started',
                                      'special_offer_shown', 'scan_completed', 'cleanup_completed', 'fast_clean_completed')
               GROUP BY 1),
        pay AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                       bool_or(p.event_type = 'trial_converted') AS converted, bool_or(p.event_type = 'renewal') AS renewed
                FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1),
        steps AS (
            SELECT 1 AS n, 'Установили' AS step, COUNT(*) AS users FROM cohort
            UNION ALL SELECT 2, 'Прошли онбординг', COUNT(*) FROM ev WHERE onb
            UNION ALL SELECT 3, 'Сканировали / чистили', COUNT(*) FROM ev WHERE used
            UNION ALL SELECT 4, 'Увидели пейвол', COUNT(*) FROM ev WHERE pw
            UNION ALL SELECT 5, 'Выбрали план', COUNT(*) FROM ev WHERE plan
            UNION ALL SELECT 6, 'Нажали «купить»', COUNT(*) FROM ev WHERE started
            UNION ALL SELECT 7, 'Увидели спецпредложение', COUNT(*) FROM ev WHERE offer
            UNION ALL SELECT 8, 'Начали триал', COUNT(*) FROM pay WHERE trial
            UNION ALL SELECT 9, 'Оплатили (любой план)', COUNT(*) FROM pay WHERE paid
            UNION ALL SELECT 10, 'Триал → оплата', COUNT(*) FROM pay WHERE converted
            UNION ALL SELECT 11, 'Продлили хотя бы раз', COUNT(*) FROM pay WHERE renewed)
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'step', s.step, 'users', s.users,
                   'pct_of_installs', ROUND(100.0 * s.users / NULLIF((SELECT users FROM steps WHERE n = 1), 0), 2))
                 ORDER BY s.n), '[]') INTO res FROM steps s;

    -- Acquisition: organic vs every media source / campaign, with cohort conversion, revenue, spend.
    WHEN 'sources' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        conv AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                        SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial) AS revenue
                 FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1),
        agg AS (SELECT c.segment, c.media_source AS source, c.campaign_id, MAX(c.campaign_name) AS campaign,
                       COUNT(*) AS installs, COUNT(*) FILTER (WHERE cv.trial) AS trials, COUNT(*) FILTER (WHERE cv.paid) AS payers,
                       COALESCE(SUM(cv.revenue), 0) AS revenue
                FROM cohort c LEFT JOIN conv cv USING (user_id) GROUP BY 1, 2, 3),
        spend AS (SELECT lower(source) AS source, campaign_id, SUM(spend_usd) AS spend
                  FROM analytics.ad_spend WHERE date >= t0::date AND ctry IS NULL GROUP BY 1, 2)
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'segment', a.segment, 'source', a.source, 'campaign', COALESCE(a.campaign, NULLIF(a.campaign_id, ''), '—'),
                   'installs', a.installs, 'trials', a.trials, 'payers', a.payers,
                   'install_to_trial_pct', ROUND(100.0 * a.trials / NULLIF(a.installs, 0), 2),
                   'install_to_paid_pct', ROUND(100.0 * a.payers / NULLIF(a.installs, 0), 2),
                   'revenue_usd', ROUND(a.revenue, 2), 'arpu_usd', ROUND(a.revenue / NULLIF(a.installs, 0), 3),
                   'spend_usd', ROUND(s.spend, 2), 'cpi_usd', ROUND(s.spend / NULLIF(a.installs, 0), 2),
                   'cac_usd', ROUND(s.spend / NULLIF(a.payers, 0), 2), 'roas_pct', ROUND(100.0 * a.revenue / NULLIF(s.spend, 0), 1))
                 ORDER BY a.installs DESC), '[]')
        INTO res FROM agg a LEFT JOIN spend s ON s.source = lower(a.source) AND s.campaign_id = a.campaign_id;

    -- Countries: where installs come from and where they pay (price / localization / ad-geo decisions).
    WHEN 'countries' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        cohort AS (SELECT * FROM su WHERE created_at >= t0),
        prev AS (SELECT country, COUNT(*) AS installs FROM su
                 WHERE created_at >= t0 - make_interval(days => d) AND created_at < t0 GROUP BY 1),
        conv AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                        SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial) AS revenue,
                        SUM(COALESCE(p.proceeds_usd, p.amount_usd * 0.7)) FILTER (WHERE NOT p.is_trial) AS proceeds
                 FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1),
        tr AS (SELECT c.country, COUNT(*) AS matured,
                      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.v_pay x WHERE x.original_transaction_id = p.original_transaction_id
                                       AND NOT x.is_trial AND x.amount_usd > 0)) AS converted
               FROM analytics.v_pay p JOIN cohort c USING (user_id)
               WHERE p.event_type = 'trial_start' AND p.occurred_at < now() - interval '4 days' GROUP BY 1),
        pw AS (SELECT DISTINCT e.user_id FROM analytics.events e JOIN cohort c USING (user_id) WHERE e.event_name = 'subview'),
        act AS (SELECT c.country, COUNT(*) FILTER (WHERE s.is_active AND s.current_status <> 'trial') AS active_paid
                FROM analytics.subscription_status s JOIN su c USING (user_id) GROUP BY 1)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.installs DESC), '[]') INTO res FROM (
            SELECT c.country, COUNT(*) AS installs, MAX(pv.installs) AS installs_prev,
                   COUNT(*) FILTER (WHERE c.segment = 'organic') AS organic_installs,
                   COUNT(*) FILTER (WHERE c.segment = 'paid') AS paid_installs,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE c.segment = 'organic') / COUNT(*), 0) AS organic_pct,
                   COUNT(pw.user_id) AS paywall_viewers,
                   ROUND(100.0 * COUNT(pw.user_id) / COUNT(*), 1) AS saw_paywall_pct,
                   COUNT(*) FILTER (WHERE cv.trial) AS trials,
                   COUNT(*) FILTER (WHERE cv.paid) AS payers,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cv.trial OR cv.paid) / COUNT(*), 2) AS install_to_sub_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cv.paid) / COUNT(*), 2) AS install_to_paid_pct,
                   ROUND(100.0 * MAX(tr.converted) / NULLIF(MAX(tr.matured), 0), 1) AS trial_to_paid_pct,
                   ROUND(COALESCE(SUM(cv.revenue), 0), 2) AS revenue_usd,
                   ROUND(COALESCE(SUM(cv.revenue) FILTER (WHERE c.segment = 'organic'), 0), 2) AS organic_revenue_usd,
                   ROUND(COALESCE(SUM(cv.revenue) FILTER (WHERE c.segment = 'paid'), 0), 2) AS paid_revenue_usd,
                   ROUND(COALESCE(SUM(cv.proceeds), 0), 2) AS proceeds_usd,
                   ROUND(COALESCE(SUM(cv.revenue), 0) / COUNT(*), 3) AS arpu_usd,
                   ROUND(SUM(cv.revenue) / NULLIF(COUNT(*) FILTER (WHERE cv.paid), 0), 2) AS arppu_usd,
                   COALESCE(MAX(a.active_paid), 0) AS active_paid
            FROM cohort c LEFT JOIN conv cv USING (user_id) LEFT JOIN pw USING (user_id)
            LEFT JOIN prev pv ON pv.country = c.country LEFT JOIN tr ON tr.country = c.country
            LEFT JOIN act a ON a.country = c.country
            GROUP BY 1 ORDER BY 2 DESC LIMIT 200) r;

    -- Countries for the filter drop-down (all-time installs; ignores the country filter).
    WHEN 'country_list' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.installs DESC), '[]') INTO res FROM (
            SELECT country, COUNT(*) AS installs, COUNT(*) FILTER (WHERE created_at >= t0) AS installs_period
            FROM analytics.seg_users(seg) GROUP BY 1) r;

    -- Products: trials, conversions, renewals, revenue, refunds per product id.
    WHEN 'products' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        pay AS (SELECT p.* FROM analytics.v_pay p JOIN su USING (user_id) WHERE p.occurred_at >= t0),
        trials AS (SELECT p.product_id, p.original_transaction_id,
                          EXISTS (SELECT 1 FROM analytics.v_pay x WHERE x.original_transaction_id = p.original_transaction_id
                                  AND NOT x.is_trial AND x.amount_usd > 0) AS converted
                   FROM pay p WHERE p.event_type = 'trial_start' AND p.occurred_at < now() - interval '4 days'),
        act AS (SELECT s.product_id, COUNT(*) FILTER (WHERE s.is_active AND s.current_status <> 'trial') AS active_paid,
                       COUNT(*) FILTER (WHERE s.is_active AND s.current_status = 'trial') AS active_trials
                FROM analytics.subscription_status s JOIN su USING (user_id) GROUP BY 1)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.revenue_usd DESC NULLS LAST), '[]') INTO res FROM (
            SELECT pr.product_id,
                   COUNT(*) FILTER (WHERE p.event_type = 'trial_start') AS trials,
                   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE converted) / NULLIF(COUNT(*), 0), 1)
                    FROM trials t WHERE t.product_id = pr.product_id) AS trial_to_paid_pct,
                   COUNT(*) FILTER (WHERE p.event_type = 'initial_purchase') AS direct_purchases,
                   COUNT(*) FILTER (WHERE p.event_type = 'trial_converted') AS trial_conversions,
                   COUNT(*) FILTER (WHERE p.event_type = 'renewal') AS renewals,
                   ROUND(COALESCE(SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial), 0), 2) AS revenue_usd,
                   ROUND(COALESCE(SUM(COALESCE(p.proceeds_usd, p.amount_usd * 0.7)) FILTER (WHERE NOT p.is_trial), 0), 2) AS proceeds_usd,
                   COUNT(*) FILTER (WHERE p.refunded) AS refunds,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE p.refunded) / NULLIF(COUNT(*) FILTER (WHERE NOT p.is_trial AND p.amount_usd > 0), 0), 1) AS refund_rate_pct,
                   COALESCE(MAX(a.active_paid), 0) AS active_paid, COALESCE(MAX(a.active_trials), 0) AS active_trials
            FROM (SELECT DISTINCT product_id FROM pay UNION SELECT product_id FROM act) pr
            LEFT JOIN pay p ON p.product_id = pr.product_id
            LEFT JOIN act a ON a.product_id = pr.product_id
            GROUP BY pr.product_id) r;

    -- Weekly trial cohorts: how many trials turned into paid subscriptions.
    WHEN 'trial_cohorts' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        t AS (SELECT date_trunc('week', p.occurred_at)::date AS week, p.original_transaction_id, p.occurred_at,
                     EXISTS (SELECT 1 FROM analytics.v_pay x WHERE x.original_transaction_id = p.original_transaction_id
                             AND NOT x.is_trial AND x.amount_usd > 0) AS converted,
                     EXISTS (SELECT 1 FROM analytics.subscription_status s WHERE s.user_id = p.user_id
                             AND s.original_transaction_id = p.original_transaction_id AND NOT s.will_renew) AS renew_off
              FROM analytics.v_pay p JOIN su USING (user_id) WHERE p.event_type = 'trial_start' AND p.occurred_at >= t0)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.week DESC), '[]') INTO res FROM (
            SELECT week, COUNT(*) AS trials, COUNT(*) FILTER (WHERE converted) AS converted,
                   COUNT(*) FILTER (WHERE NOT converted AND occurred_at >= now() - interval '4 days') AS pending,
                   COUNT(*) FILTER (WHERE NOT converted AND renew_off) AS cancelled_auto_renew,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE converted)
                         / NULLIF(COUNT(*) FILTER (WHERE converted OR occurred_at < now() - interval '4 days'), 0), 1) AS trial_to_paid_pct
            FROM t GROUP BY 1) r;

    -- Weekly install cohorts: revenue per install after 0 / 7 / 30 days and to date (LTV).
    WHEN 'ltv' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        rev AS (SELECT c.user_id, date_trunc('week', c.created_at)::date AS week,
                       SUM(p.amount_usd) FILTER (WHERE p.occurred_at < c.created_at + interval '1 day') AS d0,
                       SUM(p.amount_usd) FILTER (WHERE p.occurred_at < c.created_at + interval '7 days') AS d7,
                       SUM(p.amount_usd) FILTER (WHERE p.occurred_at < c.created_at + interval '30 days') AS d30,
                       SUM(p.amount_usd) AS total,
                       SUM(COALESCE(p.proceeds_usd, p.amount_usd * 0.7)) AS proceeds
                FROM cohort c LEFT JOIN analytics.v_pay p ON p.user_id = c.user_id AND NOT p.is_trial AND NOT p.refunded
                GROUP BY 1, 2)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.week DESC), '[]') INTO res FROM (
            SELECT week, COUNT(*) AS installs, COUNT(*) FILTER (WHERE total > 0) AS payers,
                   ROUND(COALESCE(SUM(d0), 0) / COUNT(*), 3) AS arpu_d0,
                   CASE WHEN week + 7 + 7 <= now()::date THEN ROUND(COALESCE(SUM(d7), 0) / COUNT(*), 3) END AS arpu_d7,
                   CASE WHEN week + 7 + 30 <= now()::date THEN ROUND(COALESCE(SUM(d30), 0) / COUNT(*), 3) END AS arpu_d30,
                   ROUND(COALESCE(SUM(total), 0) / COUNT(*), 3) AS arpu_to_date,
                   ROUND(COALESCE(SUM(total), 0), 2) AS revenue_usd, ROUND(COALESCE(SUM(proceeds), 0), 2) AS proceeds_usd
            FROM rev GROUP BY 1) r;

    -- Weekly install cohorts: share of users who came back on day 1 / 3 / 7 / 14 / 30.
    WHEN 'retention' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        act AS (SELECT DISTINCT s.user_id, floor(extract(epoch FROM s.started_at - c.created_at) / 86400)::int AS dn
                FROM analytics.sessions s JOIN cohort c USING (user_id)
                WHERE s.started_at >= c.created_at AND s.started_at < c.created_at + interval '31 days'),
        u AS (SELECT c.user_id, date_trunc('week', c.created_at)::date AS week, c.created_at,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 1) AS d1,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 3) AS d3,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 7) AS d7,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 14) AS d14,
                     EXISTS (SELECT 1 FROM act a WHERE a.user_id = c.user_id AND a.dn = 30) AS d30
              FROM cohort c)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.week DESC), '[]') INTO res FROM (
            SELECT week, COUNT(*) AS installs,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d1 AND created_at < now() - interval '2 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '2 days'), 0), 1) AS d1_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d3 AND created_at < now() - interval '4 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '4 days'), 0), 1) AS d3_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d7 AND created_at < now() - interval '8 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '8 days'), 0), 1) AS d7_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d14 AND created_at < now() - interval '15 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '15 days'), 0), 1) AS d14_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE d30 AND created_at < now() - interval '31 days') / NULLIF(COUNT(*) FILTER (WHERE created_at < now() - interval '31 days'), 0), 1) AS d30_pct
            FROM u GROUP BY 1) r;

    -- How fast users subscribe after install.
    WHEN 'time_to_purchase' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        f AS (SELECT c.user_id, MIN(p.occurred_at) - c.created_at AS dt
              FROM cohort c JOIN analytics.v_pay p USING (user_id) GROUP BY c.user_id, c.created_at),
        b AS (SELECT CASE WHEN dt < interval '5 minutes' THEN 1 WHEN dt < interval '1 hour' THEN 2
                          WHEN dt < interval '1 day' THEN 3 WHEN dt < interval '3 days' THEN 4
                          WHEN dt < interval '7 days' THEN 5 ELSE 6 END AS n FROM f)
        SELECT COALESCE(jsonb_agg(jsonb_build_object('when', l.label, 'subscribers', COALESCE(x.cnt, 0),
                   'share_pct', ROUND(100.0 * COALESCE(x.cnt, 0) / NULLIF((SELECT COUNT(*) FROM b), 0), 1)) ORDER BY l.n), '[]')
        INTO res
        FROM (VALUES (1, 'первые 5 мин (пейвол онбординга)'), (2, '5–60 мин'), (3, '1–24 ч'), (4, '2–3 день'),
                     (5, '4–7 день'), (6, 'позже недели')) l(n, label)
        LEFT JOIN (SELECT n, COUNT(*) AS cnt FROM b GROUP BY 1) x ON x.n = l.n;

    -- Paywall by trigger for the segment: views → buy taps → purchases, plus the plan mix.
    WHEN 'paywall' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        e AS (SELECT e.* FROM analytics.events e JOIN su USING (user_id)
              WHERE e.event_time >= t0 AND e.event_name IN ('subview', 'plan_choosing', 'purchase_started', 'subpurchase',
                                                            'purchase_cancelled', 'purchase_failed', 'paywall_cancel_click'))
        SELECT COALESCE(jsonb_agg(r ORDER BY r.viewers DESC), '[]') INTO res FROM (
            SELECT COALESCE(properties->>'trigger', 'unknown') AS trigger,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subview') AS viewers,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_started') AS tapped_buy,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subpurchase') AS purchased,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_cancelled') AS cancelled_in_apple_sheet,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_failed') AS failed,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'paywall_cancel_click') AS closed,
                   ROUND(100.0 * COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subpurchase')
                         / NULLIF(COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subview'), 0), 2) AS cr_pct,
                   ROUND(100.0 * COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'subpurchase')
                         / NULLIF(COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase_started'), 0), 1) AS tap_to_buy_pct,
                   COUNT(*) FILTER (WHERE event_name = 'subpurchase' AND properties->>'product_id' ILIKE '%week%') AS bought_weekly,
                   COUNT(*) FILTER (WHERE event_name = 'subpurchase' AND properties->>'product_id' ILIKE '%offer%') AS bought_offer,
                   COUNT(*) FILTER (WHERE event_name = 'subpurchase' AND properties->>'product_id' ILIKE '%year%'
                                    AND properties->>'product_id' NOT ILIKE '%offer%') AS bought_yearly
            FROM e GROUP BY 1) r;

    -- Which locked features make people buy (purchase within 24 h after hitting the lock).
    WHEN 'features' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        lk AS (SELECT e.user_id, e.properties->>'feature' AS feature, MIN(e.event_time) AS at
               FROM analytics.events e JOIN su USING (user_id)
               WHERE e.event_name = 'pro_feature_locked' AND e.event_time >= t0 GROUP BY 1, 2)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users_locked DESC), '[]') INTO res FROM (
            SELECT COALESCE(feature, 'other') AS feature, COUNT(*) AS users_locked,
                   COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.events s WHERE s.user_id = lk.user_id
                                    AND s.event_name = 'subpurchase' AND s.event_time BETWEEN lk.at AND lk.at + interval '24 hours')) AS bought_24h,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.events s WHERE s.user_id = lk.user_id
                                    AND s.event_name = 'subpurchase' AND s.event_time BETWEEN lk.at AND lk.at + interval '24 hours'))
                         / COUNT(*), 2) AS cr_pct
            FROM lk GROUP BY 1) r;

    -- Releases: does the new version convert better?
    WHEN 'versions' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0),
        conv AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                        SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial) AS revenue
                 FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1),
        pw AS (SELECT DISTINCT e.user_id FROM analytics.events e JOIN cohort USING (user_id) WHERE e.event_name = 'subview')
        SELECT COALESCE(jsonb_agg(r ORDER BY r.first_install DESC), '[]') INTO res FROM (
            SELECT c.app_version, MIN(c.created_at)::date AS first_install, COUNT(*) AS installs,
                   ROUND(100.0 * COUNT(pw.user_id) / COUNT(*), 1) AS saw_paywall_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cv.trial) / COUNT(*), 2) AS trial_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cv.paid) / COUNT(*), 2) AS paid_pct,
                   ROUND(COALESCE(SUM(cv.revenue), 0) / COUNT(*), 3) AS arpu_usd
            FROM cohort c LEFT JOIN conv cv USING (user_id) LEFT JOIN pw USING (user_id) GROUP BY 1) r;

    -- Churn: why and when subscribers leave.
    WHEN 'churn' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry))
        SELECT jsonb_build_object(
            'status', (SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') FROM (
                SELECT s.current_status AS status, s.product_id, COUNT(*) AS users
                FROM analytics.subscription_status s JOIN su USING (user_id) GROUP BY 1, 2) r),
            'cancel_reasons', (SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') FROM (
                SELECT COALESCE(s.cancellation_reason, 'unknown') AS reason, COUNT(*) AS users
                FROM analytics.subscription_status s JOIN su USING (user_id)
                WHERE s.cancel_date >= t0 GROUP BY 1) r),
            'cancel_after_days', (SELECT COALESCE(jsonb_agg(r ORDER BY r.n), '[]') FROM (
                SELECT CASE WHEN dd < 1 THEN 1 WHEN dd < 3 THEN 2 WHEN dd < 7 THEN 3 WHEN dd < 30 THEN 4 ELSE 5 END AS n,
                       CASE WHEN dd < 1 THEN 'в тот же день' WHEN dd < 3 THEN '1–2 день' WHEN dd < 7 THEN '3–6 день'
                            WHEN dd < 30 THEN '2–4 неделя' ELSE 'позже месяца' END AS after, COUNT(*) AS users
                FROM (SELECT extract(epoch FROM s.cancel_date - MIN(p.occurred_at)) / 86400 AS dd
                      FROM analytics.subscription_status s JOIN su USING (user_id)
                      JOIN analytics.v_pay p ON p.original_transaction_id = s.original_transaction_id
                      WHERE s.cancel_date >= t0 GROUP BY s.user_id, s.cancel_date) x
                GROUP BY 1, 2) r)
        ) INTO res;

    -- Onboarding drop-off for the segment.
    WHEN 'onboarding' THEN
        WITH cohort AS (SELECT * FROM analytics.seg_users(seg, ctry) WHERE created_at >= t0)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.idx), '[]') INTO res FROM (
            SELECT (e.properties->>'onboarding_index')::int AS idx, MAX(e.properties->>'step_name') AS step,
                   COUNT(DISTINCT e.user_id) AS users,
                   ROUND(100.0 * COUNT(DISTINCT e.user_id) / NULLIF((SELECT COUNT(*) FROM cohort), 0), 1) AS pct_of_installs
            FROM analytics.events e JOIN cohort USING (user_id)
            WHERE e.event_name = 'onboarding_steps' AND (e.properties->>'onboarding_index') ~ '^[0-9]+$'
            GROUP BY 1) r;

    -- What users do in the app (engagement drivers).
    WHEN 'engagement' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry)),
        payers AS (SELECT DISTINCT p.user_id FROM analytics.v_pay p JOIN su USING (user_id))
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT CASE WHEN e.event_name IN ('scan_completed', 'cleanup_completed') THEN e.event_name || ':' || COALESCE(e.properties->>'scan_type', '?')
                        WHEN e.event_name = 'tab_bar_tapped' THEN 'tab:' || COALESCE(e.properties->>'tab', '?')
                        ELSE e.event_name END AS action,
                   COUNT(*) AS events, COUNT(DISTINCT e.user_id) AS users,
                   COUNT(DISTINCT e.user_id) FILTER (WHERE py.user_id IS NOT NULL) AS of_them_subscribers,
                   ROUND(100.0 * COUNT(DISTINCT e.user_id) FILTER (WHERE py.user_id IS NOT NULL) / NULLIF(COUNT(DISTINCT e.user_id), 0), 1) AS subscriber_pct
            FROM analytics.events e JOIN su USING (user_id) LEFT JOIN payers py ON py.user_id = e.user_id
            WHERE e.event_time >= t0 AND e.event_name IN
                ('scan_completed', 'cleanup_completed', 'fast_clean_completed', 'charging_animation_selected',
                 'charging_animation_shown', 'widget_selected', 'widget_installed', 'tab_bar_tapped', 'review_prompt_shown',
                 'restore_tapped', 'support_opened', 'permission_result')
            GROUP BY 1 ORDER BY 3 DESC LIMIT 60) r;

    -- Hour of day (UTC) and weekday when people subscribe — for push / ad scheduling.
    WHEN 'timing' THEN
        WITH su AS (SELECT * FROM analytics.seg_users(seg, ctry))
        SELECT COALESCE(jsonb_agg(r ORDER BY r.hour_utc), '[]') INTO res FROM (
            SELECT extract(hour FROM p.occurred_at)::int AS hour_utc,
                   COUNT(*) FILTER (WHERE p.event_type = 'trial_start') AS trials,
                   COUNT(*) FILTER (WHERE p.event_type = 'initial_purchase') AS purchases
            FROM analytics.v_pay p JOIN su USING (user_id)
            WHERE p.occurred_at >= t0 AND p.event_type IN ('trial_start', 'initial_purchase') GROUP BY 1) r;

    ELSE
        RAISE EXCEPTION 'unknown growth report %', p_name USING ERRCODE = '22023';
    END CASE;
    RETURN res;
END $$;

-- Only the Worker (service_role key) may call it — same rule as the other analytics_* functions.
REVOKE ALL ON FUNCTION public.analytics_growth(TEXT, INT, TEXT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_growth(TEXT, INT, TEXT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_growth(TEXT, INT, TEXT, TEXT) TO service_role;
    END IF;
END $$;

-- Speeds up "first payment per user" and per-transaction lookups used above.
CREATE INDEX IF NOT EXISTS idx_payments_user_occurred ON analytics.payments(user_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_sessions_user_started ON analytics.sessions(user_id, started_at);

-- Tell Supabase's API (PostgREST) to pick up the new function right away.
NOTIFY pgrst, 'reload schema';
-- X Clean 2.1 — new events + "Релизы" reports in /admin (trial push, re-engagement pushes, Security Check per app version).
-- Run after 0002_growth_reports.sql (Supabase → SQL Editor → paste → Run). Idempotent: safe to run again.
--
-- Entry point: public.analytics_release(p_name, p_days, p_segment, p_country)
--   release_versions — per app version: active users, trials, trial push sent/opened, same-day trial cancels,
--                      trial→paid, Security Check usage and average score, re-engagement push opens
--   trial_push       — trials split by "opened the trial push / push sent, not opened / no push": same-day cancels, trial→paid
--   push_opens       — every push kind (trial, d1, d3, d7, d14) per version: opens and purchases within 24 h
--   security_issues  — which Security Check findings users actually have
--   security_actions — what users tap on the findings, and purchases within 24 h

-- ───────────────────────── Event catalog ─────────────────────────

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('push_scheduled',   '{kind}',   'Local push planned (kind = trial; status = scheduled / denied / disabled, delay_min, with_numbers)'),
  ('push_opened',      '{kind}',   'Local push tapped (kind = trial / d1 / d3 / d7 / d14)'),
  ('security_opened',  '{}',       'Security Check screen opened (badge = issues on the button or "new")'),
  ('security_action',  '{action}', 'Tap on a Security Check finding (action, check, items)')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

-- scan_started / scan_completed / cleanup_completed with scan_type = 'security'
UPDATE analytics.property_enums
SET allowed = (SELECT ARRAY(SELECT DISTINCT unnest(allowed || ARRAY['security'])))
WHERE property = 'scan_type' AND NOT ('security' = ANY(allowed));

-- ───────────────────────── Reports ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_release(p_name TEXT, p_days INT DEFAULT 30, p_segment TEXT DEFAULT 'all', p_country TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    t0 TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    seg TEXT := CASE WHEN p_segment IN ('organic', 'paid', 'unknown') THEN p_segment ELSE 'all' END;
    ctry TEXT := CASE WHEN upper(p_country) ~ '^([A-Z]{2}|\?\?)$' THEN upper(p_country) END;
    res JSONB;
BEGIN
    CASE p_name

    -- One row per app version: did the release change behaviour?
    WHEN 'release_versions' THEN
        WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
        ev AS (SELECT e.user_id, e.event_name, e.app_version, e.properties, e.event_time
               FROM analytics.events e JOIN su USING (user_id)
               WHERE e.event_time >= t0
                 AND e.event_name IN ('app_opened', 'push_scheduled', 'push_opened', 'security_opened', 'scan_completed')),
        tr AS (SELECT * FROM analytics.release_trials(t0, seg, ctry)),
        v AS (
            SELECT app_version,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'app_opened') AS active_users,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'security_opened') AS security_users,
                   COUNT(*) FILTER (WHERE event_name = 'scan_completed' AND properties->>'scan_type' = 'security') AS security_scans,
                   ROUND(AVG((properties->>'score')::numeric) FILTER (WHERE event_name = 'scan_completed'
                         AND properties->>'scan_type' = 'security' AND properties->>'score' ~ '^[0-9]+$'), 0) AS avg_security_score,
                   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'push_opened' AND properties->>'kind' LIKE 'd%') AS reengage_push_users
            FROM ev GROUP BY 1),
        t AS (
            SELECT app_version, COUNT(*) AS trials,
                   COUNT(*) FILTER (WHERE push_status = 'scheduled') AS trial_push_sent,
                   COUNT(*) FILTER (WHERE push_opened) AS trial_push_opened,
                   COUNT(*) FILTER (WHERE cancelled_same_day) AS cancelled_same_day,
                   COUNT(*) FILTER (WHERE matured) AS matured, COUNT(*) FILTER (WHERE matured AND converted) AS converted
            FROM tr GROUP BY 1)
        SELECT COALESCE(jsonb_agg(r), '[]') INTO res FROM (
            SELECT COALESCE(v.app_version, t.app_version) AS app_version, COALESCE(v.active_users, 0) AS active_users,
                   COALESCE(t.trials, 0) AS trials,
                   ROUND(100.0 * t.trial_push_sent / NULLIF(t.trials, 0), 1) AS trial_push_sent_pct,
                   ROUND(100.0 * t.trial_push_opened / NULLIF(t.trial_push_sent, 0), 1) AS trial_push_open_pct,
                   ROUND(100.0 * t.cancelled_same_day / NULLIF(t.trials, 0), 1) AS cancel_same_day_pct,
                   ROUND(100.0 * t.converted / NULLIF(t.matured, 0), 1) AS trial_to_paid_pct,
                   COALESCE(v.security_users, 0) AS security_users,
                   ROUND(100.0 * v.security_users / NULLIF(v.active_users, 0), 1) AS security_pct,
                   COALESCE(v.security_scans, 0) AS security_scans, v.avg_security_score,
                   COALESCE(v.reengage_push_users, 0) AS reengage_push_users
            FROM v FULL JOIN t USING (app_version)) r;

    -- Does the trial push reduce same-day cancels?
    WHEN 'trial_push' THEN
        SELECT COALESCE(jsonb_agg(r ORDER BY r.app_version DESC, r.n), '[]') INTO res FROM (
            SELECT app_version,
                   CASE WHEN push_opened THEN 1 WHEN push_status = 'scheduled' THEN 2 ELSE 3 END AS n,
                   CASE WHEN push_opened THEN 'Открыли пуш'
                        WHEN push_status = 'scheduled' THEN 'Пуш отправлен, не открыли'
                        WHEN push_status = 'denied' THEN 'Без пуша: уведомления запрещены'
                        WHEN push_status = 'disabled' THEN 'Без пуша: выключен в админке'
                        ELSE 'Без пуша: старая версия' END AS push_group,
                   COUNT(*) AS trials,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE cancelled_same_day) / COUNT(*), 1) AS cancel_same_day_pct,
                   COUNT(*) FILTER (WHERE matured) AS matured,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE matured AND converted) / NULLIF(COUNT(*) FILTER (WHERE matured), 0), 1) AS trial_to_paid_pct
            FROM analytics.release_trials(t0, seg, ctry) GROUP BY 1, 2, 3) r;

    -- Every push kind: opens and purchases within 24 h after the tap.
    WHEN 'push_opens' THEN
        WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
        o AS (SELECT e.user_id, e.app_version, e.event_time, COALESCE(e.properties->>'kind', 'unknown') AS kind
              FROM analytics.events e JOIN su USING (user_id)
              WHERE e.event_name = 'push_opened' AND e.event_time >= t0)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.app_version DESC, r.opens DESC), '[]') INTO res FROM (
            SELECT o.kind AS push_kind, o.app_version, COUNT(*) AS opens, COUNT(DISTINCT o.user_id) AS users,
                   COUNT(DISTINCT o.user_id) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.events s WHERE s.user_id = o.user_id
                         AND s.event_name = 'subpurchase' AND s.event_time BETWEEN o.event_time AND o.event_time + interval '24 hours')) AS bought_24h
            FROM o GROUP BY 1, 2) r;

    -- Which findings people actually have (latest security scan of each user in the period).
    WHEN 'security_issues' THEN
        WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
        last_scan AS (
            SELECT DISTINCT ON (e.user_id) e.user_id, COALESCE(e.properties->>'issues', '') AS issues
            FROM analytics.events e JOIN su USING (user_id)
            WHERE e.event_name = 'scan_completed' AND e.properties->>'scan_type' = 'security' AND e.event_time >= t0
            ORDER BY e.user_id, e.event_time DESC),
        total AS (SELECT COUNT(*) AS n FROM last_scan)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT x.check_name, COUNT(*) AS users, ROUND(100.0 * COUNT(*) / NULLIF((SELECT n FROM total), 0), 1) AS share_pct
            FROM last_scan l CROSS JOIN LATERAL unnest(string_to_array(NULLIF(l.issues, ''), ',')) AS x(check_name)
            GROUP BY 1) r;

    -- What people tap on the findings, and whether they buy afterwards.
    WHEN 'security_actions' THEN
        WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
        a AS (SELECT e.user_id, e.event_time, e.properties->>'action' AS action, COALESCE(e.properties->>'check', '') AS check_name
              FROM analytics.events e JOIN su USING (user_id)
              WHERE e.event_name = 'security_action' AND e.event_time >= t0)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.users DESC), '[]') INTO res FROM (
            SELECT a.action, a.check_name, COUNT(*) AS events, COUNT(DISTINCT a.user_id) AS users,
                   COUNT(DISTINCT a.user_id) FILTER (WHERE EXISTS (SELECT 1 FROM analytics.events s WHERE s.user_id = a.user_id
                         AND s.event_name = 'subpurchase' AND s.event_time BETWEEN a.event_time AND a.event_time + interval '24 hours')) AS bought_24h
            FROM a GROUP BY 1, 2) r;

    ELSE
        RAISE EXCEPTION 'unknown release report %', p_name USING ERRCODE = '22023';
    END CASE;
    RETURN res;
END $$;

-- Trials started since t0 with the app version they started in, the trial push status and the outcome.
CREATE OR REPLACE FUNCTION analytics.release_trials(t0 TIMESTAMPTZ, seg TEXT, ctry TEXT DEFAULT NULL)
RETURNS TABLE (user_id UUID, app_version TEXT, started_at TIMESTAMPTZ, push_status TEXT, push_opened BOOLEAN,
               cancelled_same_day BOOLEAN, matured BOOLEAN, converted BOOLEAN)
LANGUAGE sql STABLE SET search_path = analytics, public AS $$
    SELECT p.user_id,
           COALESCE((SELECT e.app_version FROM analytics.events e
                     WHERE e.user_id = p.user_id AND e.event_time BETWEEN p.occurred_at - interval '1 day' AND p.occurred_at + interval '1 hour'
                     ORDER BY abs(extract(epoch FROM e.event_time - p.occurred_at)) LIMIT 1), '?') AS app_version,
           p.occurred_at,
           (SELECT e.properties->>'status' FROM analytics.events e
            WHERE e.user_id = p.user_id AND e.event_name = 'push_scheduled' AND e.properties->>'kind' = 'trial'
              AND e.event_time BETWEEN p.occurred_at - interval '1 hour' AND p.occurred_at + interval '1 hour'
            ORDER BY e.event_time DESC LIMIT 1) AS push_status,
           EXISTS (SELECT 1 FROM analytics.events e
                   WHERE e.user_id = p.user_id AND e.event_name = 'push_opened' AND e.properties->>'kind' = 'trial'
                     AND e.event_time BETWEEN p.occurred_at AND p.occurred_at + interval '1 day') AS push_opened,
           EXISTS (SELECT 1 FROM analytics.subscription_status s
                   WHERE s.user_id = p.user_id AND s.original_transaction_id = p.original_transaction_id
                     AND s.cancel_date IS NOT NULL AND s.cancel_date < p.occurred_at + interval '1 day') AS cancelled_same_day,
           p.occurred_at < now() - interval '4 days' AS matured,
           EXISTS (SELECT 1 FROM analytics.v_pay c
                   WHERE c.original_transaction_id = p.original_transaction_id AND c.event_type = 'trial_converted') AS converted
    FROM analytics.v_pay p JOIN analytics.seg_users(seg, ctry) su ON su.user_id = p.user_id
    WHERE p.event_type = 'trial_start' AND p.occurred_at >= t0
$$;

-- Only the Worker (service_role key) may call it.
REVOKE ALL ON FUNCTION public.analytics_release(TEXT, INT, TEXT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_release(TEXT, INT, TEXT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_release(TEXT, INT, TEXT, TEXT) TO service_role;
    END IF;
END $$;

NOTIFY pgrst, 'reload schema';
-- X Clean — payment problems (Grace Period / billing retry) and win-back for /admin → «Деньги».
-- Run after 0003_security_check.sql (Supabase → SQL Editor → paste → Run). Idempotent: safe to run again.
--
-- Entry point: public.analytics_billing(p_name, p_days, p_segment, p_country)
--   billing_winback → { billing: funnel, billing_now: statuses, winback: funnel }

-- ───────────────────────── Event catalog ─────────────────────────

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('billing_issue_shown', '{state}', 'Banner "payment failed — update payment method" shown (state = grace / retry, where)'),
  ('billing_fix_tapped',  '{state}', '"Update payment" tapped → Apple billing page (state = grace / retry, where)')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

-- ───────────────────────── Report ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_billing(p_name TEXT, p_days INT DEFAULT 30, p_segment TEXT DEFAULT 'all', p_country TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    t0 TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    seg TEXT := CASE WHEN p_segment IN ('organic', 'paid', 'unknown') THEN p_segment ELSE 'all' END;
    ctry TEXT := CASE WHEN upper(p_country) ~ '^([A-Z]{2}|\?\?)$' THEN upper(p_country) END;
    res JSONB;
BEGIN
    IF p_name <> 'billing_winback' THEN
        RAISE EXCEPTION 'unknown billing report %', p_name USING ERRCODE = '22023';
    END IF;

    WITH su AS (SELECT user_id FROM analytics.seg_users(seg, ctry)),
    -- Apple could not charge (Adapty billing_issue_detected → payments.event_type = billing_retry)
    issue AS (SELECT p.user_id, MIN(p.occurred_at) AS at FROM analytics.v_pay p JOIN su USING (user_id)
              WHERE p.event_type = 'billing_retry' AND p.occurred_at >= t0 GROUP BY 1),
    recovered AS (SELECT DISTINCT i.user_id FROM issue i JOIN analytics.v_pay p ON p.user_id = i.user_id
                  WHERE p.event_type IN ('renewal', 'trial_converted', 'initial_purchase') AND p.occurred_at > i.at),
    ev AS (SELECT e.user_id, e.event_name, e.properties FROM analytics.events e JOIN su USING (user_id)
           WHERE e.event_time >= t0 AND e.event_name IN ('billing_issue_shown', 'billing_fix_tapped', 'subview', 'subpurchase', 'push_opened')),
    cancelled AS (SELECT s.user_id FROM analytics.subscription_status s JOIN su USING (user_id)
                  WHERE s.cancel_date >= t0 AND COALESCE(s.cancellation_reason, '') <> 'billing_error'),
    n AS (SELECT
        (SELECT COUNT(*) FROM issue) AS issues,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'billing_issue_shown') AS banner,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'billing_fix_tapped') AS fix,
        (SELECT COUNT(*) FROM recovered) AS recovered,
        (SELECT COUNT(*) FROM cancelled) AS cancelled,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'subview' AND properties->>'trigger' = 'win_back') AS wb_seen,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'push_opened' AND properties->>'kind' = 'winback') AS wb_push,
        (SELECT COUNT(DISTINCT user_id) FROM ev WHERE event_name = 'subpurchase' AND properties->>'trigger' = 'win_back') AS wb_bought)
    SELECT jsonb_build_object(
        'billing', jsonb_build_array(
            jsonb_build_object('step', 'Оплата не прошла (Apple не смогла списать)', 'users', n.issues, 'pct', CASE WHEN n.issues > 0 THEN 100 END),
            jsonb_build_object('step', 'Увидели баннер «Обновите оплату»', 'users', n.banner, 'pct', ROUND(100.0 * n.banner / NULLIF(n.issues, 0), 1)),
            jsonb_build_object('step', 'Нажали «Обновить оплату»', 'users', n.fix, 'pct', ROUND(100.0 * n.fix / NULLIF(n.issues, 0), 1)),
            jsonb_build_object('step', 'Оплата прошла после ошибки', 'users', n.recovered, 'pct', ROUND(100.0 * n.recovered / NULLIF(n.issues, 0), 1))),
        'billing_now', (SELECT COALESCE(jsonb_agg(r ORDER BY r.n), '[]') FROM (
            SELECT 1 AS n, 'Сейчас в Grace Period (PRO работает, оплата ещё не прошла)' AS status,
                   COUNT(*) FILTER (WHERE s.current_status = 'in_grace_period') AS users FROM analytics.subscription_status s JOIN su USING (user_id)
            UNION ALL
            SELECT 2, 'Сейчас в billing retry (PRO выключен, Apple повторяет списание)',
                   COUNT(*) FILTER (WHERE s.current_status = 'billing_issue') FROM analytics.subscription_status s JOIN su USING (user_id)
            UNION ALL
            SELECT 3, 'Потеряны из-за ошибки оплаты за период',
                   COUNT(*) FILTER (WHERE s.cancellation_reason = 'billing_error' AND s.cancel_date >= t0)
            FROM analytics.subscription_status s JOIN su USING (user_id)) r),
        'winback', jsonb_build_array(
            jsonb_build_object('step', 'Сами отключили автопродление', 'users', n.cancelled, 'pct', CASE WHEN n.cancelled > 0 THEN 100 END),
            jsonb_build_object('step', 'Увидели win-back', 'users', n.wb_seen, 'pct', ROUND(100.0 * n.wb_seen / NULLIF(n.cancelled, 0), 1)),
            jsonb_build_object('step', 'Открыли win-back пуш', 'users', n.wb_push, 'pct', ROUND(100.0 * n.wb_push / NULLIF(n.cancelled, 0), 1)),
            jsonb_build_object('step', 'Купили на win-back (% от увидевших)', 'users', n.wb_bought, 'pct', ROUND(100.0 * n.wb_bought / NULLIF(n.wb_seen, 0), 1)))
    ) INTO res FROM n;
    RETURN res;
END $$;

REVOKE ALL ON FUNCTION public.analytics_billing(TEXT, INT, TEXT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_billing(TEXT, INT, TEXT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_billing(TEXT, INT, TEXT, TEXT) TO service_role;
    END IF;
END $$;

NOTIFY pgrst, 'reload schema';
-- X Clean — A/B test of the paywall via /admin, new paywall events, Adapty webhook matching by profile_id.
-- Run after 0004_billing_winback.sql (Supabase → SQL Editor → paste → Run). Idempotent: safe to run again.
--
-- Entry point: public.analytics_ab(p_name, p_days, p_segment, p_country)
--   ab_summary → one row per variant: users, saw paywall, tapped buy, cancelled Apple sheet, trials, paid, revenue
--   ab_funnel  → install funnel (same steps as «Воронка») split by variant: [{variant, step, users, pct_of_installs}]

-- ───────────────────────── Event catalog (app v2.1) ─────────────────────────

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('paywall_shown',       '{trigger,placement_id}', 'Paywall screen appeared (placement_id = Adapty placement, ab_variant)'),
  ('paywall_closed',      '{placement_id}',         'Paywall screen left (purchased = true/false)'),
  ('paywall_load_failed', '{placement_id}',         'Products could not be loaded (attempt, error)'),
  ('post_scan_paywall',   '{}',                     'Paywall after the first scan is about to be shown (bytes, duplicates)'),
  ('ab_assigned',         '{test,variant}',         'A/B variant assigned to a new user (test = ab_test_name, variant = A/B, traffic)')
ON CONFLICT (event_name) DO UPDATE SET required = EXCLUDED.required, description = EXCLUDED.description;

-- trigger = post_scan (paywall after the first scan)
UPDATE analytics.property_enums
SET allowed = (SELECT ARRAY(SELECT DISTINCT unnest(allowed || ARRAY['post_scan'])))
WHERE property = 'trigger' AND NOT ('post_scan' = ANY(allowed));

-- ───────────────────────── A/B variant per user ─────────────────────────

-- Variant of a user: the ab_assigned event (sent once), otherwise the last ab_variant seen on any event.
CREATE OR REPLACE FUNCTION analytics.ab_users(test_name TEXT DEFAULT NULL)
RETURNS TABLE (user_id UUID, variant TEXT, test TEXT)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT ON (e.user_id) e.user_id,
           upper(e.properties->>'variant'), e.properties->>'test'
    FROM analytics.events e
    WHERE e.event_name = 'ab_assigned'
      AND e.properties->>'variant' IN ('A', 'B', 'a', 'b')
      AND (test_name IS NULL OR e.properties->>'test' = test_name)
    ORDER BY e.user_id, e.event_time DESC
$$;

CREATE OR REPLACE FUNCTION public.analytics_ab(p_name TEXT, p_days INT DEFAULT 30, p_segment TEXT DEFAULT 'all', p_country TEXT DEFAULT NULL, p_test TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    t0 TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    seg TEXT := CASE WHEN p_segment IN ('organic', 'paid', 'unknown') THEN p_segment ELSE 'all' END;
    ctry TEXT := CASE WHEN upper(p_country) ~ '^([A-Z]{2}|\?\?)$' THEN upper(p_country) END;
    tst TEXT := NULLIF(left(COALESCE(p_test, ''), 64), '');
    res JSONB;
BEGIN
    CASE p_name

    WHEN 'ab_summary' THEN
        WITH cohort AS (SELECT c.user_id, c.created_at, v.variant, v.test
                        FROM analytics.seg_users(seg, ctry) c JOIN analytics.ab_users(tst) v USING (user_id)
                        WHERE c.created_at >= t0),
        ev AS (SELECT e.user_id,
                      bool_or(e.event_name IN ('subview', 'paywall_shown')) AS pw,
                      bool_or(e.event_name = 'purchase_started') AS started,
                      bool_or(e.event_name = 'purchase_cancelled') AS cancelled,
                      bool_or(e.event_name IN ('scan_completed', 'cleanup_completed', 'fast_clean_completed')) AS used
               FROM analytics.events e JOIN cohort c USING (user_id)
               WHERE e.event_time >= c.created_at - interval '1 hour'
                 AND e.event_name IN ('subview', 'paywall_shown', 'purchase_started', 'purchase_cancelled',
                                      'scan_completed', 'cleanup_completed', 'fast_clean_completed')
               GROUP BY 1),
        pay AS (SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                       bool_or(p.event_type = 'trial_converted') AS converted,
                       SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial) AS revenue, bool_or(p.refunded) AS refunded
                FROM analytics.v_pay p JOIN cohort USING (user_id) GROUP BY 1)
        SELECT COALESCE(jsonb_agg(r ORDER BY r.variant), '[]') INTO res FROM (
            SELECT c.variant, MAX(c.test) AS test, COUNT(*) AS users,
                   COUNT(*) FILTER (WHERE ev.pw) AS saw_paywall,
                   COUNT(*) FILTER (WHERE ev.started) AS tapped_buy,
                   COUNT(*) FILTER (WHERE ev.cancelled) AS cancelled_in_apple_sheet,
                   COUNT(*) FILTER (WHERE ev.used) AS used_app,
                   COUNT(*) FILTER (WHERE pay.trial) AS trials,
                   COUNT(*) FILTER (WHERE pay.paid) AS payers,
                   COUNT(*) FILTER (WHERE pay.converted) AS trial_converted,
                   COUNT(*) FILTER (WHERE pay.refunded) AS refunded,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE ev.started) / NULLIF(COUNT(*) FILTER (WHERE ev.pw), 0), 1) AS paywall_to_tap_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE pay.trial OR pay.paid) / NULLIF(COUNT(*) FILTER (WHERE ev.started), 0), 1) AS tap_to_start_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE pay.trial) / NULLIF(COUNT(*), 0), 2) AS install_to_trial_pct,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE pay.paid) / NULLIF(COUNT(*), 0), 2) AS install_to_paid_pct,
                   ROUND(COALESCE(SUM(pay.revenue), 0), 2) AS revenue_usd,
                   ROUND(COALESCE(SUM(pay.revenue), 0) / NULLIF(COUNT(*), 0), 3) AS arpu_usd
            FROM cohort c LEFT JOIN ev USING (user_id) LEFT JOIN pay USING (user_id)
            GROUP BY c.variant) r;

    WHEN 'ab_funnel' THEN
        WITH cohort AS (SELECT c.user_id, c.created_at, v.variant
                        FROM analytics.seg_users(seg, ctry) c JOIN analytics.ab_users(tst) v USING (user_id)
                        WHERE c.created_at >= t0),
        ev AS (SELECT c.variant, e.user_id,
                      bool_or(e.event_name = 'onboarding_completed') AS onb,
                      bool_or(e.event_name IN ('subview', 'paywall_shown')) AS pw,
                      bool_or(e.event_name = 'plan_choosing') AS plan,
                      bool_or(e.event_name = 'purchase_started') AS started,
                      bool_or(e.event_name = 'special_offer_shown') AS offer,
                      bool_or(e.event_name IN ('scan_completed', 'cleanup_completed', 'fast_clean_completed')) AS used
               FROM analytics.events e JOIN cohort c USING (user_id)
               WHERE e.event_time >= c.created_at - interval '1 hour'
                 AND e.event_name IN ('onboarding_completed', 'subview', 'paywall_shown', 'plan_choosing', 'purchase_started',
                                      'special_offer_shown', 'scan_completed', 'cleanup_completed', 'fast_clean_completed')
               GROUP BY 1, 2),
        pay AS (SELECT c.variant, p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                       bool_or(p.event_type = 'trial_converted') AS converted, bool_or(p.event_type = 'renewal') AS renewed
                FROM analytics.v_pay p JOIN cohort c USING (user_id) GROUP BY 1, 2),
        steps AS (
            SELECT variant, 1 AS n, 'Установили' AS step, COUNT(*) AS users FROM cohort GROUP BY 1
            UNION ALL SELECT variant, 2, 'Прошли онбординг', COUNT(*) FROM ev WHERE onb GROUP BY 1
            UNION ALL SELECT variant, 3, 'Сканировали / чистили', COUNT(*) FROM ev WHERE used GROUP BY 1
            UNION ALL SELECT variant, 4, 'Увидели пейвол', COUNT(*) FROM ev WHERE pw GROUP BY 1
            UNION ALL SELECT variant, 5, 'Выбрали план', COUNT(*) FROM ev WHERE plan GROUP BY 1
            UNION ALL SELECT variant, 6, 'Нажали «купить»', COUNT(*) FROM ev WHERE started GROUP BY 1
            UNION ALL SELECT variant, 7, 'Увидели спецпредложение', COUNT(*) FROM ev WHERE offer GROUP BY 1
            UNION ALL SELECT variant, 8, 'Начали триал', COUNT(*) FROM pay WHERE trial GROUP BY 1
            UNION ALL SELECT variant, 9, 'Оплатили (любой план)', COUNT(*) FROM pay WHERE paid GROUP BY 1
            UNION ALL SELECT variant, 10, 'Триал → оплата', COUNT(*) FROM pay WHERE converted GROUP BY 1
            UNION ALL SELECT variant, 11, 'Продлили хотя бы раз', COUNT(*) FROM pay WHERE renewed GROUP BY 1),
        base AS (SELECT variant, users FROM steps WHERE n = 1)
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'variant', s.variant, 'step', s.step, 'n', s.n, 'users', s.users,
                   'pct_of_installs', ROUND(100.0 * s.users / NULLIF(b.users, 0), 2))
                 ORDER BY s.variant, s.n), '[]')
        INTO res FROM steps s JOIN base b USING (variant);

    ELSE
        RAISE EXCEPTION 'unknown ab report %', p_name USING ERRCODE = '22023';
    END CASE;
    RETURN res;
END $$;

-- ───────────────────────── Adapty webhook: match by profile_id too ─────────────────────────
-- The app now sends `user.adapty_profile_id` with every batch, so a webhook whose customer_user_id is missing
-- (profiles created by the old app) or unknown (webhook arrived before the first batch) can still be attributed.

CREATE OR REPLACE FUNCTION public.analytics_adapty_webhook(body JSONB)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    t TEXT := body->>'event_type';
    p JSONB := COALESCE(body->'event_properties', '{}'::jsonb);
    customer TEXT := lower(COALESCE(body->>'customer_user_id', ''));
    prof TEXT := NULLIF(body->>'profile_id', '');
    uid UUID;
    product TEXT;
    orig TEXT;
    occurred TIMESTAMPTZ;
    ptype TEXT;
    pay_id UUID;
    st TEXT;
    active BOOLEAN;
    renew BOOLEAN;
BEGIN
    IF t IS NULL THEN RETURN 'ping'; END IF;

    IF analytics.is_uuid(customer) THEN
        SELECT user_id INTO uid FROM users WHERE user_id = customer::uuid;
    END IF;
    IF uid IS NULL AND prof IS NOT NULL THEN
        -- fallback: the app reported this Adapty profile id in its analytics batches
        SELECT user_id INTO uid FROM users WHERE adapty_profile_id = prof ORDER BY last_seen_at DESC LIMIT 1;
    END IF;
    IF uid IS NULL THEN
        -- TZ 9.3: never create a user silently
        INSERT INTO integration_anomalies (kind, details, raw_payload)
        VALUES (CASE WHEN customer = '' THEN 'missing_customer_user_id' ELSE 'unknown_customer_user_id' END,
                format('%s profile=%s customer=%s', t, COALESCE(prof, '-'), COALESCE(NULLIF(customer, ''), '-')), body);
        INSERT INTO webhook_log (source, event_type, status) VALUES ('adapty', t, 'anomaly');
        RETURN 'anomaly';
    END IF;

    IF prof IS NOT NULL THEN
        UPDATE users SET adapty_profile_id = COALESCE(adapty_profile_id, prof) WHERE user_id = uid;
    END IF;

    product := COALESCE(p->>'vendor_product_id', p->>'product_id', 'unknown');
    orig := COALESCE(p->>'original_transaction_id', p->>'transaction_id', 'unknown');
    occurred := COALESCE(analytics.try_ts(p->>'event_datetime'), analytics.try_ts(body->>'event_datetime'), now());

    -- payments: append-only, dedup by transaction_id
    ptype := CASE t
        WHEN 'trial_started' THEN 'trial_start'
        WHEN 'trial_converted' THEN 'trial_converted'
        WHEN 'subscription_started' THEN 'initial_purchase'
        WHEN 'subscription_initial_purchase' THEN 'initial_purchase'
        WHEN 'subscription_renewed' THEN 'renewal'
        WHEN 'billing_issue_detected' THEN 'billing_retry'
        WHEN 'non_subscription_purchase' THEN 'one_time_purchase'
    END;
    IF ptype IS NOT NULL AND COALESCE(p->>'transaction_id', '') <> '' THEN
        INSERT INTO payments (transaction_id, user_id, product_id, event_type, is_recurring, amount_usd, proceeds_usd, currency,
                              original_transaction_id, occurred_at, is_trial, environment, raw_payload)
        VALUES (p->>'transaction_id', uid, product, ptype, ptype <> 'one_time_purchase',
                CASE WHEN ptype = 'trial_start' THEN 0 ELSE NULLIF(p->>'price_usd', '')::numeric END,
                CASE WHEN ptype = 'trial_start' THEN 0 ELSE NULLIF(p->>'proceeds_usd', '')::numeric END,
                p->>'currency', orig, occurred, ptype = 'trial_start', p->>'environment', body)
        ON CONFLICT (transaction_id) DO NOTHING;
    END IF;

    -- refunds: one per transaction
    IF t IN ('subscription_refunded', 'non_subscription_purchase_refunded', 'trial_refunded') THEN
        SELECT payment_id INTO pay_id FROM payments WHERE transaction_id = p->>'transaction_id';
        IF pay_id IS NULL THEN
            INSERT INTO integration_anomalies (kind, details, raw_payload)
            VALUES ('refund_without_payment', format('%s txn=%s', t, COALESCE(p->>'transaction_id', '-')), body);
        ELSE
            INSERT INTO refunds (payment_id, status, amount_usd, reason, requested_at, processed_at, raw_payload)
            VALUES (pay_id, 'processed', NULLIF(p->>'price_usd', '')::numeric,
                    COALESCE(p->>'cancellation_reason', p->>'refund_reason'), occurred, occurred, body)
            ON CONFLICT (payment_id) DO UPDATE SET status = 'processed', processed_at = EXCLUDED.processed_at, raw_payload = EXCLUDED.raw_payload;
        END IF;
    END IF;

    -- subscription_status: access_level_updated is the source of truth (upsert)
    IF t = 'access_level_updated' THEN
        active := COALESCE((p->>'is_active')::boolean, false);
        renew := COALESCE((p->>'will_renew')::boolean, false);
        st := CASE
            WHEN NOT active THEN 'expired'
            WHEN COALESCE(p->>'billing_issue_detected_at', '') <> '' THEN 'billing_issue'
            WHEN COALESCE((p->>'is_in_grace_period')::boolean, false) THEN 'in_grace_period'
            WHEN p->>'active_introductory_offer_type' = 'free_trial' THEN 'trial'
            WHEN NOT renew THEN 'cancelled'
            ELSE 'active' END;
        INSERT INTO subscription_status (user_id, original_transaction_id, product_id, current_status, is_active, will_renew,
                                         expires_at, cancel_date, cancellation_reason, raw_payload, updated_at)
        VALUES (uid, orig, product, st, active, renew, analytics.try_ts(p->>'expires_at'),
                analytics.try_ts(p->>'unsubscribed_at'), p->>'cancellation_reason', body, now())
        ON CONFLICT (user_id) DO UPDATE SET
            original_transaction_id = EXCLUDED.original_transaction_id, product_id = EXCLUDED.product_id,
            current_status = EXCLUDED.current_status, is_active = EXCLUDED.is_active, will_renew = EXCLUDED.will_renew,
            expires_at = EXCLUDED.expires_at,
            cancel_date = CASE WHEN EXCLUDED.will_renew THEN NULL ELSE COALESCE(EXCLUDED.cancel_date, subscription_status.cancel_date) END,
            cancellation_reason = COALESCE(EXCLUDED.cancellation_reason, subscription_status.cancellation_reason),
            raw_payload = EXCLUDED.raw_payload, updated_at = now();
    ELSIF t IN ('subscription_renewal_cancelled', 'trial_renewal_cancelled') THEN
        UPDATE subscription_status SET current_status = 'cancelled', will_renew = false, cancel_date = occurred,
               cancellation_reason = COALESCE(p->>'cancellation_reason', cancellation_reason), updated_at = now()
        WHERE user_id = uid;
    ELSIF t IN ('subscription_renewal_reactivated', 'trial_renewal_reactivated') THEN
        UPDATE subscription_status SET current_status = CASE WHEN t LIKE 'trial%' THEN 'trial' ELSE 'active' END,
               will_renew = true, cancel_date = NULL, updated_at = now() WHERE user_id = uid;
    ELSIF t IN ('subscription_expired', 'trial_expired') THEN
        UPDATE subscription_status SET current_status = 'expired', is_active = false, will_renew = false, updated_at = now() WHERE user_id = uid;
    ELSIF t = 'entered_grace_period' THEN
        UPDATE subscription_status SET current_status = 'in_grace_period', updated_at = now() WHERE user_id = uid;
    ELSIF t = 'billing_issue_detected' THEN
        UPDATE subscription_status SET current_status = 'billing_issue', updated_at = now() WHERE user_id = uid;
    ELSIF t = 'subscription_paused' THEN
        UPDATE subscription_status SET current_status = 'paused', is_active = false, updated_at = now() WHERE user_id = uid;
    END IF;

    INSERT INTO webhook_log (source, event_type, status) VALUES ('adapty', t, 'ok');
    RETURN 'ok';
END $$;

CREATE INDEX IF NOT EXISTS idx_users_adapty_profile ON analytics.users(adapty_profile_id) WHERE adapty_profile_id IS NOT NULL;

-- Permissions, same as the other report entry points.
REVOKE ALL ON FUNCTION public.analytics_ab(TEXT, INT, TEXT, TEXT, TEXT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_ab(TEXT, INT, TEXT, TEXT, TEXT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_ab(TEXT, INT, TEXT, TEXT, TEXT) TO service_role;
    END IF;
END $$;
-- X Clean — CRM in /admin: user list + user card, in-app feedback (rating before the free gift cleanup).
-- Run after 0005_ab_paywall.sql. Idempotent: safe to run again (CI runs every file on each push).
--
-- Entry point: public.analytics_crm(p_name, p_days, p_query, p_user, p_filter, p_limit)
--   feedback_summary → {shown, rated, avg_stars, stars:[{stars,users}], high, low, skipped, with_text, system_prompts, gift:{…}}
--   feedback         → newest first: [{event_time, user_id, stars, text, country, app_version, status}]
--   users            → [{user_id, created_at, last_seen_at, country, app_version, source, campaign, organic, status, product_id,
--                        will_renew, revenue_usd, sessions, events, stars, feedback}]
--                       p_query = beginning of user_id / Adapty profile id; p_filter = all|paying|trial|churned|free|feedback
--   user             → {profile, device, attribution, subscription, payments[], feedback[], events[]}  (p_user = user_id)
-- Raw payloads, IP, IDFV and push tokens are never returned.

-- ───────────────────────── Event catalog (app v2.3–2.4) ─────────────────────────

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('free_clean_gift_shown',    '{}', 'Free Fast Clean gift offered (paywall + special offer closed without buying)'),
  ('free_clean_gift_accepted', '{}', 'Free Fast Clean gift accepted'),
  ('free_clean_gift_declined', '{}', 'Free Fast Clean gift declined'),
  ('free_clean_gift_used',     '{}', 'Free Fast Clean done (items, bytes)'),
  ('rate_cleanup_shown',       '{}', 'In-app "How do you like X Clean?" screen shown'),
  ('rate_cleanup_stars',       '{}', 'Stars tapped on the in-app rating screen (stars = 1..5)'),
  ('rate_cleanup_skipped',     '{}', 'In-app rating skipped (stars when skipped on the feedback form)'),
  ('rate_cleanup_feedback',    '{}', 'Written feedback after 1–3 stars (stars, text ≤ 1000 chars)'),
  ('mail_opened',              '{}', 'Mail section opened'),
  ('mail_accounts_opened',     '{}', 'Mail accounts screen opened'),
  ('mail_coming_soon_shown',   '{}', 'Mail section switched off in /admin → "Coming soon" shown'),
  ('mail_sign_in_started',     '{}', 'Mail sign-in started (provider)'),
  ('mail_sign_in_completed',   '{}', 'Mail sign-in completed (provider)'),
  ('mail_sign_in_cancelled',   '{}', 'Mail sign-in cancelled (provider)'),
  ('mail_sign_in_failed',      '{}', 'Mail sign-in failed (provider, error)'),
  ('mail_sign_out',            '{}', 'Mail account signed out'),
  ('mail_app_password_help',   '{}', 'Opened the app-password help'),
  ('mail_clean_tapped',        '{}', 'Mail cleanup action tapped'),
  ('mail_unsubscribe',         '{}', 'Unsubscribe from a sender tapped'),
  ('files_opened',             '{}', 'Files cleanup opened'),
  ('files_folder_added',       '{}', 'Folder added in Files cleanup'),
  ('compress_filter',          '{}', 'Filter changed in Compress')
ON CONFLICT (event_name) DO NOTHING;

-- Events of these names that arrived before they were in the catalog were parked as unknown_event — move them back.
INSERT INTO analytics.events (event_id, user_id, session_id, event_name, event_time, received_at, properties, app_version, platform)
SELECT DISTINCT ON (r.event_id) r.event_id, r.user_id, r.session_id, r.event_name, r.event_time, r.received_at, r.properties,
       COALESCE(r.app_version, 'unknown'), CASE WHEN r.platform = 'android' THEN 'android' ELSE 'ios' END
FROM analytics.events_rejected r
WHERE r.rejection_reason = 'unknown_event'
  AND r.event_name IN (SELECT event_name FROM analytics.event_catalog)
  AND r.event_id IS NOT NULL AND r.user_id IS NOT NULL AND r.session_id IS NOT NULL
  AND r.event_time BETWEEN now() - interval '90 days' AND now() + interval '1 day'
ON CONFLICT DO NOTHING;
DELETE FROM analytics.events_rejected
WHERE rejection_reason = 'unknown_event' AND event_name IN (SELECT event_name FROM analytics.event_catalog);

CREATE INDEX IF NOT EXISTS idx_users_last_seen ON analytics.users(last_seen_at DESC);

-- ───────────────────────── Helpers ─────────────────────────

-- Subscription state as shown in the CRM: active / trial / billing_issue / cancelled / expired / free
CREATE OR REPLACE FUNCTION analytics.crm_status(s analytics.subscription_status)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN s.user_id IS NULL THEN 'free'
        WHEN s.current_status IN ('billing_issue', 'in_grace_period') THEN 'billing_issue'
        WHEN s.is_active AND s.current_status = 'trial' THEN 'trial'
        WHEN s.is_active AND NOT s.will_renew THEN 'cancelled'
        WHEN s.is_active THEN 'active'
        ELSE 'expired' END
$$;

-- ───────────────────────── Entry point ─────────────────────────

CREATE OR REPLACE FUNCTION public.analytics_crm(p_name TEXT, p_days INT DEFAULT 30, p_query TEXT DEFAULT NULL,
                                                p_user TEXT DEFAULT NULL, p_filter TEXT DEFAULT 'all', p_limit INT DEFAULT 100)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = analytics, public AS $$
DECLARE
    since TIMESTAMPTZ := now() - make_interval(days => GREATEST(1, LEAST(COALESCE(p_days, 30), 730)));
    lim INT := GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));
    q TEXT := NULLIF(lower(btrim(COALESCE(p_query, ''))), '');
    uid UUID;
    res JSONB;
BEGIN
    IF p_name = 'feedback_summary' THEN
        WITH ev AS (
            SELECT event_name, user_id, properties FROM events
            WHERE event_time >= since AND event_name IN ('rate_cleanup_shown', 'rate_cleanup_stars', 'rate_cleanup_skipped',
                  'rate_cleanup_feedback', 'review_prompt_shown', 'free_clean_gift_shown', 'free_clean_gift_accepted',
                  'free_clean_gift_declined', 'free_clean_gift_used')
        ), st AS (
            SELECT DISTINCT ON (user_id) user_id, (properties->>'stars')::int AS stars
            FROM ev WHERE event_name = 'rate_cleanup_stars' AND COALESCE(properties->>'stars', '') ~ '^[1-5]$'
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
                                   AND p.occurred_at >= since))
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
            WHERE e.event_name = 'rate_cleanup_feedback' AND e.event_time >= since
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
            WHERE (q IS NOT NULL AND (u.user_id::text LIKE q || '%' OR lower(COALESCE(u.adapty_profile_id, '')) LIKE q || '%'))
               OR (q IS NULL AND COALESCE(u.last_seen_at, u.created_at) >= since
                   AND CASE COALESCE(p_filter, 'all')
                       WHEN 'paying'   THEN analytics.crm_status(s) IN ('active', 'cancelled', 'billing_issue')
                       WHEN 'trial'    THEN analytics.crm_status(s) = 'trial'
                       WHEN 'churned'  THEN analytics.crm_status(s) IN ('expired', 'cancelled')
                       WHEN 'free'     THEN analytics.crm_status(s) = 'free'
                       WHEN 'feedback' THEN EXISTS (SELECT 1 FROM events e WHERE e.user_id = u.user_id
                                                    AND e.event_name IN ('rate_cleanup_stars', 'rate_cleanup_feedback'))
                       ELSE true END)
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

REVOKE ALL ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.analytics_crm(TEXT, INT, TEXT, TEXT, TEXT, INT) TO service_role;
    END IF;
END $$;
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
-- X Clean — install source details: OneLink / ad-link parameters per user (channel, deep_link_value, sub params…).
-- Run after 0011. Idempotent.
--
-- * user_attribution: + channel, deep_link_value, params (every normalised parameter the app received from AppsFlyer).
-- * analytics_ingest: the `attribution` event fills them; a second event (deferred deep link resolved later, or
--   Apple Ads found after an "Organic" answer) MERGES: params are unioned, and a real media_source replaces organic.
-- * event catalog: deep_link_opened (OneLink / Universal Link opened, deferred = install link).
-- * analytics_crm 'links': installs / trials / payers / revenue per source · campaign · channel · deep_link_value · sub1.

ALTER TABLE analytics.user_attribution ADD COLUMN IF NOT EXISTS channel TEXT;
ALTER TABLE analytics.user_attribution ADD COLUMN IF NOT EXISTS deep_link_value TEXT;
ALTER TABLE analytics.user_attribution ADD COLUMN IF NOT EXISTS params JSONB NOT NULL DEFAULT '{}';

INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('deep_link_opened', '{}', 'OneLink / Universal Link resolved (deep_link_value, dl_sub1…, media_source, campaign, deferred)')
ON CONFLICT (event_name) DO NOTHING;

DO $patch$
DECLARE src TEXT; orig TEXT;
BEGIN
    src := pg_get_functiondef('public.analytics_ingest(jsonb,text)'::regprocedure);
    orig := src;
    IF position('deep_link_value, params' IN src) = 0 THEN
        src := replace(src,
            'INSERT INTO user_attribution (user_id, install_at, utm_source, campaign_id, campaign_name, adset_id, adset_name,
                                          ad_id, ad_name, attribution_source, is_organic)',
            'INSERT INTO user_attribution (user_id, install_at, utm_source, campaign_id, campaign_name, adset_id, adset_name,
                                          ad_id, ad_name, attribution_source, is_organic, channel, deep_link_value, params)');
        src := replace(src,
            '                         ELSE ''paid_unattributed'' END)
            ON CONFLICT (user_id) DO NOTHING;',
            '                         ELSE ''paid_unattributed'' END,
                    p->>''channel'', p->>''deep_link_value'', p - ''status'' - ''install_time'' - ''deferred'')
            ON CONFLICT (user_id) DO UPDATE SET
                params = user_attribution.params || EXCLUDED.params,
                channel = COALESCE(EXCLUDED.channel, user_attribution.channel),
                deep_link_value = COALESCE(EXCLUDED.deep_link_value, user_attribution.deep_link_value),
                utm_source    = CASE WHEN user_attribution.is_organic <> ''paid_attributed'' AND EXCLUDED.is_organic = ''paid_attributed'' THEN EXCLUDED.utm_source    ELSE user_attribution.utm_source    END,
                campaign_id   = CASE WHEN user_attribution.is_organic <> ''paid_attributed'' AND EXCLUDED.is_organic = ''paid_attributed'' THEN EXCLUDED.campaign_id   ELSE user_attribution.campaign_id   END,
                campaign_name = CASE WHEN user_attribution.is_organic <> ''paid_attributed'' AND EXCLUDED.is_organic = ''paid_attributed'' THEN EXCLUDED.campaign_name ELSE user_attribution.campaign_name END,
                adset_id      = CASE WHEN user_attribution.is_organic <> ''paid_attributed'' AND EXCLUDED.is_organic = ''paid_attributed'' THEN EXCLUDED.adset_id      ELSE user_attribution.adset_id      END,
                adset_name    = CASE WHEN user_attribution.is_organic <> ''paid_attributed'' AND EXCLUDED.is_organic = ''paid_attributed'' THEN EXCLUDED.adset_name    ELSE user_attribution.adset_name    END,
                ad_id         = CASE WHEN user_attribution.is_organic <> ''paid_attributed'' AND EXCLUDED.is_organic = ''paid_attributed'' THEN EXCLUDED.ad_id         ELSE user_attribution.ad_id         END,
                ad_name       = CASE WHEN user_attribution.is_organic <> ''paid_attributed'' AND EXCLUDED.is_organic = ''paid_attributed'' THEN EXCLUDED.ad_name       ELSE user_attribution.ad_name       END,
                is_organic    = CASE WHEN user_attribution.is_organic <> ''paid_attributed'' AND EXCLUDED.is_organic = ''paid_attributed'' THEN EXCLUDED.is_organic    ELSE user_attribution.is_organic    END;');
        IF src = orig THEN RAISE EXCEPTION 'analytics_ingest: attribution INSERT not found — patch 0012 needs updating'; END IF;
        EXECUTE src;
        RAISE NOTICE 'analytics_ingest patched (link params)';
    END IF;
END $patch$;

-- 'links' report inside analytics_crm (keeps the 7-arg signature from 0011).
DO $patch$
DECLARE src TEXT;
BEGIN
    src := pg_get_functiondef('public.analytics_crm(text,integer,text,text,text,integer,text)'::regprocedure);
    IF position('p_name = ''links''' IN src) > 0 THEN RETURN; END IF;
    src := replace(src, '    IF p_name = ''version_list'' THEN',
'    IF p_name = ''links'' THEN
        WITH cohort AS (
            SELECT u.user_id, a.utm_source, COALESCE(a.campaign_name, a.campaign_id) AS campaign, a.channel, a.deep_link_value,
                   COALESCE(a.params->>''sub1'', a.params->>''dl_sub1'') AS sub1, a.is_organic
            FROM users u LEFT JOIN user_attribution a ON a.user_id = u.user_id
            WHERE u.created_at >= since AND u.created_at < until_ts
        ), conv AS (
            SELECT p.user_id, bool_or(p.is_trial) AS trial, bool_or(NOT p.is_trial AND p.amount_usd > 0) AS paid,
                   SUM(p.amount_usd) FILTER (WHERE NOT p.is_trial) AS revenue
            FROM payments p JOIN cohort USING (user_id) GROUP BY 1)
        SELECT COALESCE(jsonb_agg(x ORDER BY (x->>''installs'')::int DESC), ''[]'') INTO res FROM (
            SELECT jsonb_build_object(
                ''source'', CASE WHEN c.is_organic = ''organic'' THEN ''Organic'' ELSE COALESCE(c.utm_source, CASE WHEN c.is_organic IS NULL THEN ''—'' ELSE ''Paid'' END) END,
                ''campaign'', COALESCE(c.campaign, ''—''), ''channel'', COALESCE(c.channel, ''—''),
                ''deep_link_value'', COALESCE(c.deep_link_value, ''—''), ''sub1'', COALESCE(c.sub1, ''—''),
                ''installs'', COUNT(*), ''trials'', COUNT(*) FILTER (WHERE cv.trial), ''payers'', COUNT(*) FILTER (WHERE cv.paid),
                ''install_to_paid_pct'', ROUND(100.0 * COUNT(*) FILTER (WHERE cv.paid) / COUNT(*), 2),
                ''revenue_usd'', ROUND(COALESCE(SUM(cv.revenue), 0), 2)) AS x
            FROM cohort c LEFT JOIN conv cv USING (user_id)
            GROUP BY c.is_organic, c.utm_source, c.campaign, c.channel, c.deep_link_value, c.sub1) t;
        RETURN res;
    END IF;

    IF p_name = ''version_list'' THEN');
    EXECUTE src;
    RAISE NOTICE 'analytics_crm: links report added';
END $patch$;
-- X Clean — launch_action event: a link asked the app to do something (showRating / offer / security). Idempotent.
INSERT INTO analytics.event_catalog (event_name, required, description) VALUES
  ('launch_action', '{action}', 'Link action performed (action = showrating / offer / security; source = scheme / link / deferred)')
ON CONFLICT (event_name) DO NOTHING;
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
-- 0015: /admin → Отзывы → «Запросили окно App Store» counts the system review prompt of both rating flows:
-- the free gift (where = free_clean_gift) and the show_rating link (where = deep_link). Idempotent.
DO $patch$
DECLARE src TEXT;
BEGIN
    src := pg_get_functiondef('public.analytics_crm(text,integer,text,text,text,integer,text)'::regprocedure);
    IF position($q$properties->>'where' = 'free_clean_gift'$q$ IN src) > 0 THEN
        src := replace(src, $q$properties->>'where' = 'free_clean_gift'$q$,
                            $q$properties->>'where' IN ('free_clean_gift', 'deep_link')$q$);
        EXECUTE src;
    END IF;
END $patch$;
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
