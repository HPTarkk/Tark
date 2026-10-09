// Dependency-free preview of the static deployment, including email rewrites.
import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../website/', import.meta.url));
const port = Number(process.env.TARK_SITE_PORT || 4183);
const mime = { '.html':'text/html; charset=utf-8', '.css':'text/css; charset=utf-8', '.js':'text/javascript; charset=utf-8', '.json':'application/json', '.svg':'image/svg+xml', '.png':'image/png', '.webp':'image/webp', '.jpg':'image/jpeg', '.ico':'image/x-icon', '.woff2':'font/woff2', '.ttf':'font/ttf', '.txt':'text/plain; charset=utf-8' };
http.createServer(async (req, res) => {
  try {
    let path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    if (/^\/v\/(register|reset|email)\/?$/.test(path)) path = '/v/';
    if (/^\/(?:fa\/)?(?:privacy|terms|delete-account)$/.test(path)) path += '.html';
    let file = resolve(root, '.' + path);
    if (!file.startsWith(resolve(root) + sep) && file !== resolve(root)) {res.writeHead(403);res.end();return;}
    if ((await stat(file)).isDirectory()) file = resolve(file, 'index.html');
    const data = await readFile(file);
    const headers = { 'Content-Type':mime[extname(file)] || 'application/octet-stream', 'Cache-Control':'no-store' };
    if (path.startsWith('/v/')) {
      headers['Content-Security-Policy'] = "default-src 'none'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
      headers['Referrer-Policy'] = 'no-referrer'; headers['X-Robots-Tag'] = 'noindex, nofollow';
    }
    if (path === '/update.json' || path === '/.well-known/assetlinks.json') headers['Access-Control-Allow-Origin'] = '*';
    res.writeHead(200, headers); res.end(data);
  } catch { res.writeHead(404, {'Content-Type':'text/plain'}); res.end('Not found'); }
}).listen(port, '127.0.0.1', () => console.log(`Main website preview: http://127.0.0.1:${port}/fa/`));
