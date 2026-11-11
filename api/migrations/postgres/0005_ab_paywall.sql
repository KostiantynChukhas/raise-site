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
