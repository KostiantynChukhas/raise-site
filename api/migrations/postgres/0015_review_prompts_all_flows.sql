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
