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
