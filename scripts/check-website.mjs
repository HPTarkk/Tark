// Static integration checks: public routes, bilingual SEO, assets, and protected
// script-free account links. Run after both website generators.
import assert from 'node:assert/strict';
import { readFile, readdir, stat } from 'node:fs/promises';
import { resolve, dirname, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
const root = fileURLToPath(new URL('../', import.meta.url));
const site = resolve(root, 'website');
for (const script of ['build-website-i18n.mjs', 'build-legal-pages.mjs']) {
  execFileSync(process.execPath, [resolve(root, 'scripts', script), '--check'], { stdio: 'inherit' });
}
const files = [];
async function walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = resolve(dir, entry.name);
    if (entry.isDirectory()) await walk(path); else files.push(path);
  }
}
await walk(site);
let references = 0;
async function verifyRef(ref, file) {
  if (!ref || /^(?:https?:|data:|mailto:|tel:|#|\/\/)/.test(ref) || ref.includes('${')) return;
  const path = decodeURIComponent(ref.split(/[?#]/)[0]);
  let target = path.startsWith('/') ? resolve(site, '.' + path) : resolve(dirname(file), path);
  assert(target === site || target.startsWith(site + sep), `Path escapes website: ${ref} in ${file}`);
  if (/\/v\/(?:register|reset|email)\/?$/.test(path)) target = resolve(site, 'v/index.html');
  if (/(?:^|\/)(?:privacy|terms|delete-account)$/.test(path)) target += '.html';
  let info; try { info = await stat(target); } catch { assert.fail(`Missing asset/page: ${ref} in ${file}`); }
  if (info.isDirectory()) await stat(resolve(target, 'index.html'));
  references++;
}
for (const file of files) {
  const ext = extname(file);
  if (!['.html', '.css', '.js'].includes(ext)) continue;
  if (file.includes(sep + 'vendor' + sep)) continue;
  const source = await readFile(file, 'utf8');
  if (ext === '.html') {
    if (source.includes('<html lang="fa"') && source.includes('id="pageLoader"')) {
      const critical = source.match(/<style id="loaderFontCss">([\s\S]*?)<\/style>/)?.[1];
      assert(critical, `Persian loader must have its font in the initial HTML: ${file}`);
      const fonts = [...critical.matchAll(/data:font\/woff2;base64,([A-Za-z0-9+/=]+)/g)];
      assert.equal(fonts.length, 2, 'Loader needs its two real font weights');
      const data = fonts.map(font => Buffer.from(font[1], 'base64'));
      assert(data.every(font => font.subarray(0, 4).toString() === 'wOF2'), 'Invalid inline loader font');
      assert(data.reduce((bytes, font) => bytes + font.length, 0) < 12000, 'Loader subset must remain small');
      assert(source.indexOf('id="loaderFontCss"') < source.indexOf('rel="stylesheet"'), 'Loader font must precede external CSS');
    }
    for (const m of source.matchAll(/\b(?:src|href)="([^"]+)"/g)) await verifyRef(m[1], file);
    for (const m of source.matchAll(/\bhref="#([^"\s]+)"/g)) assert(source.includes(`id="${m[1]}"`), `Missing anchor #${m[1]} in ${file}`);
  }
  if (ext === '.css') for (const m of source.matchAll(/url\(["']?([^"')]+)["']?\)/g)) await verifyRef(m[1], file);
  if (ext === '.js') {
    execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
    for (const m of source.matchAll(/\bfrom\s+["']([^"']+)["']/g)) await verifyRef(m[1], file);
  }
}
const navOrder = ['handshake', 'features', 'music', 'tech'];
async function verifySocialImage(html, lang) {
  const filename = lang === 'fa' ? 'og-image.png' : 'og-image-en.png';
  const url = `https://tarkk.ir/${filename}`;
  assert.equal(html.match(/<meta property="og:image" content="([^"]+)"/)?.[1], url, `Wrong ${lang} Open Graph image`);
  assert.equal(html.match(/<meta name="twitter:image" content="([^"]+)"/)?.[1], url, `Wrong ${lang} Twitter image`);
  const png = await readFile(resolve(site, filename));
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', `Invalid ${lang} social PNG`);
  assert.equal(png.readUInt32BE(16), 1200, `Wrong ${lang} social image width`);
  assert.equal(png.readUInt32BE(20), 630, `Wrong ${lang} social image height`);
}
for (const lang of ['en', 'fa']) {
  const prefix = lang === 'fa' ? 'fa/' : '';
  const html = await readFile(resolve(site, prefix, 'index.html'), 'utf8');
  await verifySocialImage(html, lang);
  assert(html.includes(`<html lang="${lang}" dir="${lang === 'fa' ? 'rtl' : 'ltr'}"`));
  assert(html.includes(`rel="canonical" href="https://tarkk.ir/${prefix}"`));
  assert(!html.includes('noindex'), 'Production landing must be indexable');
  assert(!html.includes('cdn.jsdelivr.net'), 'Fonts and motion must load locally');
  const nav = html.match(/<div class="nav-links" id="navLinks">([\s\S]*?)<\/div>/)[1];
  assert.deepEqual([...nav.matchAll(/href="#([^"]+)"/g)].map(m => m[1]), navOrder);
  assert(navOrder.every((id, i) => i === 0 || html.indexOf(`id="${navOrder[i - 1]}"`) < html.indexOf(`id="${id}"`)));
  const ld = JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
  const faq = ld['@graph'].find(node => node['@type'] === 'FAQPage');
  assert(faq.mainEntity.length === (html.match(/<details class="faq-item">/g) || []).length);
  assert(faq.inLanguage === lang);
  const bodyText = html.split('<body>')[1].replace(/<script\b[\s\S]*?<\/script>/g, '').replace(/<[^>]*>/g, '');
  if (lang === 'en') assert(!/[\u0600-\u06ff]/.test(bodyText), 'English static body has untranslated Persian text');
  for (const page of ['privacy', 'terms', 'delete-account']) {
    const legal = await readFile(resolve(site, prefix, page + '.html'), 'utf8');
    await verifySocialImage(legal, lang);
    assert(legal.includes(`rel="canonical" href="https://tarkk.ir/${prefix}${page}"`));
    assert(legal.includes('/legal-page.js?v=site-1'));
    const legalNav = legal.match(/<div class="nav-links" id="navLinks">([\s\S]*?)<\/div>/)[1];
    assert.deepEqual([...legalNav.matchAll(/href="[^"#]*#([^"]+)"/g)].map(m => m[1]), navOrder);
  }
}
const email = await readFile(resolve(site, 'v/index.html'), 'utf8');
assert(!/<script\b/i.test(email), 'Email-token fallback must never run a script');
assert(!/https?:\/\/[^" ]+\.(?:js|css|woff2)/i.test(email), 'Email-token fallback must not request third parties');
assert(email.includes("default-src 'none'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'"));
for (const name of ['privacy.json', 'terms.json', 'index.json']) {
  assert.equal(await readFile(resolve(site, 'legal', name), 'utf8'), await readFile(resolve(root, 'assets/legal', name), 'utf8'), `Bundled legal source drift: ${name}`);
}
JSON.parse(await readFile(resolve(site, 'update.json'), 'utf8'));
JSON.parse(await readFile(resolve(site, '.well-known/assetlinks.json'), 'utf8'));
const sitemap = await readFile(resolve(site, 'sitemap.xml'), 'utf8');
assert(!/\.html(?:"|<\/loc>)/.test(sitemap), 'Sitemap must use the host’s final canonical URLs');
assert.equal((sitemap.match(/<url>/g) || []).length, 8);
console.log(`Website checks passed: 8 localized pages, email fallback, ${references} local references, syntax and legal bundles.`);
