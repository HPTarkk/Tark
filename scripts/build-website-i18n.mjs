// English is the hand-edited landing source; FAQ copy lives in content.js.
// Generates static localized markup and matching structured data for crawlers
// and visitors without JavaScript. --check verifies both generated regions.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { translateMarkup, escapeHtml, landingSeo, startup, loaderFontCss } from './website-shared.mjs';
const site = new URL('../website/', import.meta.url);
const read = async path => (await readFile(new URL(path, site), 'utf8')).replace(/\r\n/g, '\n');
const { faqItems } = await import('data:text/javascript;base64,' + Buffer.from(await read('content.js')).toString('base64'));
const check = process.argv.includes('--check');
const original = await read('index.html');
function build(source, lang) {
  let html = source.replace(/<html\b[^>]*>/, `<html lang="${lang}" dir="${lang === 'fa' ? 'rtl' : 'ltr'}" data-theme="dark">`);
  const loaderFont = `<!-- LOADER-FONT-START -->\n${loaderFontCss(lang)}\n<!-- LOADER-FONT-END -->`;
  if (html.includes('<!-- LOADER-FONT-START -->')) html = html.replace(/<!-- LOADER-FONT-START -->[\s\S]*?<!-- LOADER-FONT-END -->/, loaderFont);
  else html = html.replace(/<meta charset="utf-8"\s*\/>/, `$&\n${loaderFont}`);
  html = html.replace(/<!-- SITE-STARTUP -->|<!-- STARTUP-START -->[\s\S]*?<!-- STARTUP-END -->/, `<!-- STARTUP-START -->\n${startup(lang, '/fa/')}\n<!-- STARTUP-END -->`);
  html = html.replace(/<!-- SITE-SEO -->|<!-- SEO-START -->[\s\S]*?<!-- SEO-END -->/, landingSeo(lang, faqItems));
  const faq = faqItems.map(item => `<details class="faq-item"><summary><span class="faq-arrow" aria-hidden="true"></span>${escapeHtml(item[lang + 'Question'])}</summary><p>${escapeHtml(item[lang + 'Answer'])}</p></details>`).join('\n');
  if (!html.includes('<!-- FAQ-START -->')) throw new Error('Missing static FAQ region');
  html = html.replace(/<!-- FAQ-START -->[\s\S]*?<!-- FAQ-END -->/, `<!-- FAQ-START -->\n${faq}\n<!-- FAQ-END -->`);
  html = translateMarkup(html, lang);
  html = html.replace(/(data-legal="([^"]+)"\s+href=")[^"]+"/g, (_, prefix, page) => prefix + (lang === 'fa' ? '/fa/' : '/') + page + '"');
  html = html.replace(/(<button id="langToggle" class="language-button">)[^<]+/, '$1' + (lang === 'fa' ? 'انگلیسی' : 'Persian'));
  const aria = [
    ['منوی اصلی', 'Main navigation'], ['گوشی تَرک کنار تجهیزات سفر', 'Tarkk phone alongside riding gear'],
    ['گوشی، کلاه و دستکش موتورسواری روی میز آماده‌سازی سفر', 'A phone, helmet and riding gloves on a travel preparation table'],
    ['چطور کار می‌کند', 'How it works'], ['منو', 'Menu'], ['نمایش مکالمه', 'Conversation demo'],
    ['مراحل اتصال', 'Connection steps'], ['روش‌های اتصال', 'Connection methods'], ['تَرک', 'Tarkk'],
  ];
  for (const [fa, en] of aria) {
    html = html.replaceAll(`aria-label="${lang === 'fa' ? en : fa}"`, `aria-label="${lang === 'fa' ? fa : en}"`);
    html = html.replaceAll(`alt="${lang === 'fa' ? en : fa}"`, `alt="${lang === 'fa' ? fa : en}"`);
  }
  html = html.replace(/(<output id="loadPercent">)[^<]+/, '$1' + (lang === 'fa' ? '۰٪' : '0%'));
  if (lang === 'en') {
    html = html.replace(/>([^<>]*[۰-۹][^<>]*)</g, (whole, text) => /^\s*[۰-۹\s/٪%.–—+-]+\s*$/.test(text) ? '>' + text.replace(/[۰-۹]/g, d => '۰۱۲۳۴۵۶۷۸۹'.indexOf(d)).replace(/٪/g, '%') + '<' : whole);
  }
  if (lang === 'fa') {
    html = html.replace(/>([^<>]*\d[^<>]*)</g, (whole, text) => /^\s*[\d\s/%.–—+-]+\s*$/.test(text) ? '>' + text.replace(/\d/g, d => '۰۱۲۳۴۵۶۷۸۹'[d]).replace(/%/g, '٪') + '<' : whole);
  }
  return html;
}
let stale = 0;
for (const [path, lang] of [['index.html', 'en'], ['fa/index.html', 'fa']]) {
  const expected = build(original, lang);
  let current; try { current = await read(path); } catch { current = ''; }
  if (check) {
    if (current !== expected) { console.error(`website/${path} is out of date`); stale++; }
  } else {
    await mkdir(new URL('./', new URL(path, site)), { recursive: true });
    await writeFile(new URL(path, site), expected);
    console.log(`wrote website/${path} — ${faqItems.length} FAQ entries`);
  }
}
if (stale) { console.error('Run node scripts/build-website-i18n.mjs'); process.exitCode = 1; }
else if (check) console.log('Landing localization and FAQ structured data are current.');
