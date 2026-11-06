// tarkk.ir edge script. Everything is a static asset; the Worker runs first
// only for the English home page "/" (see run_worker_first in
// wrangler.website.jsonc), so every other path is served directly.
//
// Its one job: tell the home page which country the visitor is in, so a
// visitor with no language of their own yet can start in Persian when they
// are in Iran. The decision itself stays in the page's startup script
// (scripts/website-shared.mjs), because only the page can see the visitor's
// remembered choice (localStorage) — and that choice must always win.
//
// Only the two-letter country code Cloudflare already derived is passed on;
// the visitor's IP address never reaches the page.

const COUNTRY = /^[A-Z]{2}$/;
// Cloudflare's placeholders: XX = unknown, T1 = Tor.
const UNKNOWN = new Set(['XX', 'T1']);

export function visitorCountry(request) {
  const country = String(request.cf?.country || '').toUpperCase();
  return COUNTRY.test(country) && !UNKNOWN.has(country) ? country : '';
}

export async function handle(request, env) {
  const country = visitorCountry(request);
  if (!country || (request.method !== 'GET' && request.method !== 'HEAD')) return env.ASSETS.fetch(request);
  // The page differs per country, so a browser's cached copy (an If-None-Match
  // 304) could carry another country's value. The home page is small; always
  // send it whole and keep it out of shared caches.
  const plain = new Request(request);
  plain.headers.delete('If-None-Match');
  plain.headers.delete('If-Modified-Since');
  const response = await env.ASSETS.fetch(plain);
  if (response.status !== 200 || !(response.headers.get('Content-Type') || '').includes('text/html')) return response;
  const headers = new Headers(response.headers);
  headers.delete('ETag');
  headers.delete('Last-Modified');
  headers.set('Cache-Control', 'private, no-cache');
  const tagged = new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  return new HTMLRewriter()
    .on('html', { element(root) { root.setAttribute('data-country', country); } })
    .transform(tagged);
}

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch {
      // Never let the hint take the home page down: serve it untouched, and
      // the page falls back to the visitor's time zone.
      return env.ASSETS.fetch(request);
    }
  },
};
