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
