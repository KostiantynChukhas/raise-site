// Supabase access via PostgREST RPC. All business logic lives in SQL functions
// (migrations/postgres/0001_init.sql), so the Worker stays thin and the DB enforces the rules.
// Secrets (Cloudflare → Workers & Pages → raise-api → Settings → Variables and Secrets):
//   SUPABASE_URL               https://<project-ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY  Supabase → Project Settings → API Keys → service_role / secret key
// extraHeaders: e.g. X-Range-From / X-Range-To (0007_date_range.sql reads them via request.headers).
export async function rpc(env, fn, args, extraHeaders) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) throw new Error("supabase_not_configured");
  const res = await fetch(`${env.SUPABASE_URL.replace(/\/$/, "")}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      ...(extraHeaders || {}),
    },
    body: JSON.stringify(args || {}),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`supabase ${fn} ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}
