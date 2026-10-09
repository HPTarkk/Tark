import { readFileSync } from 'node:fs';
export const ORIGIN = 'https://tarkk.ir';
export const escapeHtml = value => String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
export function translateMarkup(html, lang) {
  return html.replace(/<([\w-]+)\b([^>]*\bdata-(?:fa|en)="[^>]*?)>([^<]*)<\/\1\s*>/g, (whole, tag, attrs) => {
    const match = attrs.match(new RegExp(`\\bdata-${lang}="([^"]*)"`));
    if (!match) throw new Error(`Missing ${lang} translation: ${whole.slice(0, 100)}`);
    return `<${tag}${attrs}>${match[1]}</${tag}>`;
  });
}
export function startup(lang, faPath) {
  return `<script>
    (() => {
      const root = document.documentElement;
      let requested = new URLSearchParams(location.search).get('lang');
      let preference = null;
      try {
        if (requested === 'en' || requested === 'fa') localStorage.setItem('tark_lang', requested);
        preference = localStorage.getItem('tark_lang');
      } catch {}
      // A fresh crawler/visitor receives the actual URL's complete language.
      // Only an explicit remembered Persian choice can redirect English URLs.
      if (root.lang === 'en' && preference === 'fa') {
        location.replace(${JSON.stringify(faPath)} + location.search + location.hash);
        return;
      }
      history.scrollRestoration = 'manual';
      // Keep incoming cross-page anchors. A plain reload still starts at the top.
      const reload = performance.getEntriesByType('navigation')[0]?.type === 'reload';
      if (reload && location.hash) history.replaceState(null, '', location.pathname + location.search);
      window.scrollTo(0, 0);
      root.classList.add('is-enhanced', 'is-booting');
      // Content must remain accessible if an optional motion script fails.
      setTimeout(() => {
        if (!root.classList.contains('page-loaded')) {
          root.classList.remove('is-booting'); root.classList.add('page-loaded');
          document.getElementById('pageLoader')?.remove();
        }
      }, 10000);
    })();
  </script>`;
}
export function loaderMarkup(lang) {
  return translateMarkup(readFileSync(new URL('./website-loader.html', import.meta.url), 'utf8'), lang)
    .replace(/<output id="loadPercent">.*?<\/output>/, `<output id="loadPercent">${lang === 'fa' ? '۰٪' : '0%'}</output>`);
}
export function loaderFontCss(lang) {
  if (lang !== 'fa') return '';
  const fonts = JSON.parse(readFileSync(new URL('./loader-fonts.json', import.meta.url), 'utf8'));
  const faces = Object.entries(fonts).map(([weight, data]) =>
    `@font-face{font-family:TarkkLoader;src:url(data:font/woff2;base64,${data}) format("woff2");font-weight:${weight};font-display:block;}`
  ).join('\n');
  return `<style id="loaderFontCss">\n${faces}
html[lang="fa"] .page-loader :is(.loader-kicker,.loader-center>strong,.loader-center>span,.loader-center>output){font-family:TarkkLoader,Vazirmatn,Arial,sans-serif;font-weight:500}
html[lang="fa"] .page-loader .loader-center>strong{font-weight:900}
</style>`;
}
export const SITE_META = {
  en: { title: 'Tarkk — Walkie-talkie app, even off-grid', description: 'Tarkk turns your phone into a walkie-talkie. Talk over Bluetooth, Wi-Fi or a hotspot—no internet for local calls, and no conversation recording.', image: `${ORIGIN}/og-image-en.png`, imageAlt: 'Tarkk phone beside motorcycle gear, with the message “Same road. Stay close.”' },
  fa: { title: 'تَرک — بیسیم بدون اینترنت، کنار هم در مسیر', description: 'تَرک، بیسیم بدون اینترنت روی گوشی شما. با بلوتوث، وای‌فای یا هات‌اسپات مستقیم با اطرافیانت حرف بزن؛ ارتباط محلی، بدون ضبط مکالمه.', image: `${ORIGIN}/og-image.png`, imageAlt: 'گوشی تَرک کنار تجهیزات موتورسواری با شعار «هم‌مسیر، هم‌صدا.»' },
};
export function landingSeo(lang, faqItems) {
  const m = SITE_META[lang], other = lang === 'fa' ? 'en' : 'fa';
  const url = ORIGIN + (lang === 'fa' ? '/fa/' : '/');
  const meta = (name, key, property = false) => `<meta ${property ? 'property' : 'name'}="${name}" content="${escapeHtml(m[key])}" data-meta-fa="${escapeHtml(SITE_META.fa[key])}" data-meta-en="${escapeHtml(SITE_META.en[key])}">`;
  const graph = [
    { '@type': 'Organization', '@id': ORIGIN + '/#organization', name: 'Tarkk', url: ORIGIN, logo: ORIGIN + '/logo.png', sameAs: ['https://github.com/HPTarkk/Tark'] },
    { '@type': 'WebSite', '@id': url + '#website', url, name: lang === 'fa' ? 'تَرک' : 'Tarkk', inLanguage: lang, description: m.description, publisher: { '@id': ORIGIN + '/#organization' } },
    { '@type': 'MobileApplication', '@id': url + '#app', name: 'Tarkk', operatingSystem: 'Android', applicationCategory: 'CommunicationApplication', url, downloadUrl: 'https://cafebazaar.ir/app/com.b1101.tark', description: m.description, inLanguage: lang, publisher: { '@id': ORIGIN + '/#organization' } },
    { '@type': 'FAQPage', '@id': url + '#faq', inLanguage: lang, mainEntity: faqItems.map(item => ({ '@type': 'Question', name: item[lang + 'Question'], acceptedAnswer: { '@type': 'Answer', text: item[lang + 'Answer'] } })) },
  ];
  return `<!-- SEO-START -->
    <title>${escapeHtml(m.title)}</title>
    ${meta('description', 'description')}
    <meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1">
    <meta name="theme-color" content="#0D1913">
    <link rel="canonical" href="${url}">
    <link rel="alternate" hreflang="en" href="${ORIGIN}/">
    <link rel="alternate" hreflang="fa" href="${ORIGIN}/fa/">
    <link rel="alternate" hreflang="x-default" href="${ORIGIN}/fa/">
    <link rel="apple-touch-icon" href="/logo.png">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Tarkk">
    <meta property="og:url" content="${url}">
    ${meta('og:title', 'title', true)}
    ${meta('og:description', 'description', true)}
    ${meta('og:image', 'image', true)}
    <meta property="og:image:width" content="1200">
    <meta property="og:image:height" content="630">
    ${meta('og:image:alt', 'imageAlt', true)}
    <meta property="og:locale" content="${lang === 'fa' ? 'fa_IR' : 'en_US'}" data-meta-fa="fa_IR" data-meta-en="en_US">
    <meta property="og:locale:alternate" content="${other === 'fa' ? 'fa_IR' : 'en_US'}" data-meta-fa="en_US" data-meta-en="fa_IR">
    <meta name="twitter:card" content="summary_large_image">
    ${meta('twitter:title', 'title')}
    ${meta('twitter:description', 'description')}
    ${meta('twitter:image', 'image')}
    <script type="application/ld+json">${JSON.stringify({ '@context': 'https://schema.org', '@graph': graph }).replace(/</g, '\\u003c')}</script>
    <!-- SEO-END -->`;
}
