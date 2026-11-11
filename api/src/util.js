// JSON responses. CORS: the admin lives on GitHub Pages (ADMIN_ORIGIN), so /admin/api/* answers that origin.
export function json(data, status = 200, extra) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...(extra || {}) },
  });
}

export function corsHeaders(request, env) {
  const origin = request.headers.get("Origin") || "";
  const allowed = String(env.ADMIN_ORIGIN || "").split(",").map(s => s.trim()).filter(Boolean);
  if (!origin || !allowed.includes(origin)) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

/** Copies a response and adds CORS headers for the admin origin. */
export function withCors(response, request, env) {
  const h = corsHeaders(request, env);
  if (!Object.keys(h).length) return response;
  const r = new Response(response.body, response);
  for (const [k, v] of Object.entries(h)) r.headers.set(k, v);
  return r;
}
