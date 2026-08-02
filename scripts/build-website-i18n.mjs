// Generates website/fa/index.html from website/index.html.
//
// The site is bilingual, and for search each language has to be its own URL
// with its own <title>, description, social tags and structured data —
// otherwise Google sees one document whose metadata contradicts the text it
// actually renders. Rather than maintain two copies of a 900-line page, the
// English file stays the single source: every translatable node already
// carries a data-fa attribute (that is how the old client-side toggle
// worked), so the Persian document can be derived from it.
//
//   node scripts/build-website-i18n.mjs
//   node scripts/build-website-i18n.mjs --check   (CI: verify, write nothing)
//
// What is derived, and what is not: the body text comes from data-fa, and
// the Persian FAQ structured data is rebuilt from the Persian FAQ markup, so
// those can never fall out of step. The head strings have no home in the
// markup, so they live in FA below — that is the one place to edit Persian
// metadata.
//
// This also verifies the *English* FAQ structured data against the English
// markup. That pair is hand-maintained on both sides and had already drifted
// once; a rich result that quotes text the page does not contain is worth
// failing a build over.

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(ROOT, 'website', 'index.html');
const OUT = join(ROOT, 'website', 'fa', 'index.html');

const ORIGIN = 'https://tarkk.ir';
const EN_URL = `${ORIGIN}/`;
const FA_URL = `${ORIGIN}/fa/`;

// ── Persian head metadata ────────────────────────────────────────────
// The only Persian copy that is not already in index.html as a data-fa
// attribute. Keep the description under ~160 characters so search results
// do not truncate it mid-sentence.
const FA = {
  title: 'تَرک — بیسیم بدون اینترنت برای حرف زدن با اطرافیان',
  description:
    'تَرک گوشی‌های نزدیک رو مستقیم با وای‌فای یا بلوتوث به هم وصل می‌کنه تا بدون اینترنت و بدون حساب کاربری با هم حرف بزنید.',
  twitterDescription:
    'با وای‌فای یا بلوتوث با آدمای نزدیکت حرف بزن. بدون اینترنت، بدون حساب کاربری، بدون ذخیره شدن.',
  imageAlt: 'تَرک — فوری حرف بزنید، بدون آنتن و بدون اینترنت.',
  siteDescription:
    'اپلیکیشن بیسیم که گوشی‌های نزدیک رو با وای‌فای یا بلوتوث به هم وصل می‌کنه، بدون اینترنت و بدون حساب کاربری.',
  appDescription:
    'تَرک یه اپلیکیشن بیسیمه که گوشی‌های نزدیک رو مستقیم با وای‌فای یا بلوتوث به هم وصل می‌کنه. نه اینترنت می‌خواد، نه حساب کاربری، و هیچی از حرفاتون ذخیره یا آپلود نمی‌شه.',
  featureList: [
    'حرف زدن با دکمه فشاری روی وای‌فای دایرکت یا بلوتوث',
    'کار کردن بدون آنتن و بدون اینترنت',
    'اجرا در پس‌زمینه با صفحه قفل',
    'اتصال دوباره خودکار وقتی طرف مقابل به محدوده برمی‌گرده',
    'حذف نویز محیط',
    'ورود با مرورگر بدون نیاز به نصب',
  ],
};

const fail = (msg) => {
  console.error(`\n  build-website-i18n: ${msg}\n`);
  process.exit(1);
};

/** Attribute values are HTML-escaped; JSON-LD holds plain text. */
const decodeEntities = (s) =>
  s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&'); // last: an unescaped & must not revive an entity

/**
 * Every element carrying both data-en and data-fa, with the source text it
 * wraps. These elements only ever contain text — the toggle they were built
 * for assigned textContent, which would have destroyed any children — and
 * that is asserted rather than assumed, since it is what makes a regex a
 * safe tool here.
 */
function collectTranslatable(html) {
  const re = /<([a-zA-Z0-9]+)\b([^>]*\bdata-en="[^"]*"[^>]*)>([\s\S]*?)<\/\1\s*>/g;
  const found = [];
  for (const m of html.matchAll(re)) {
    const [full, tag, attrs, inner] = m;
    const fa = attrs.match(/\bdata-fa="([^"]*)"/);
    const en = attrs.match(/\bdata-en="([^"]*)"/);
    if (inner.includes('<')) {
      fail(
        `<${tag} data-en="${en[1].slice(0, 40)}..."> contains markup. ` +
          `Translatable elements must hold text only.`
      );
    }
    found.push({ full, tag, attrs, inner, en: en[1], fa: fa ? fa[1] : null });
  }
  return found;
}

/** Rewrites each translatable element's body to its Persian text. */
function translate(html, nodes) {
  let out = html;
  for (const n of nodes) {
    if (!n.fa) continue; // no translation supplied — leave the English
    out = out.replace(n.full, `<${n.tag}${n.attrs}>${n.fa}</${n.tag}>`);
  }
  return out;
}

/**
 * The six FAQ entries, both languages, read out of the markup. Each
 * .faq-item holds exactly two translatable nodes: the question in .faq-q
 * and the answer in .faq-a-inner.
 */
function collectFaq(html) {
  const section = html.match(/<div class="faq reveal">([\s\S]*?)<\/section>/);
  if (!section) fail('could not find the FAQ block in index.html');

  const items = section[1].split(/<div class="faq-item">/).slice(1);
  if (!items.length) fail('found the FAQ block but no .faq-item entries');

  return items.map((chunk, i) => {
    const pairs = collectTranslatable(chunk);
    if (pairs.length !== 2) {
      fail(
        `FAQ item ${i + 1} has ${pairs.length} translatable nodes, expected 2 ` +
          `(one question, one answer)`
      );
    }
    const [q, a] = pairs;
    if (!q.fa || !a.fa) fail(`FAQ item ${i + 1} is missing a data-fa translation`);
    return {
      q: { en: decodeEntities(q.en), fa: decodeEntities(q.fa) },
      a: { en: decodeEntities(a.en), fa: decodeEntities(a.fa) },
    };
  });
}

const faqEntities = (faq, lang) =>
  faq.map(({ q, a }) => ({
    '@type': 'Question',
    name: q[lang],
    acceptedAnswer: { '@type': 'Answer', text: a[lang] },
  }));

/** Reads the single JSON-LD block, and where in the file it sits. */
function readJsonLd(html) {
  const m = html.match(
    /(<script type="application\/ld\+json">\s*)([\s\S]*?)(\s*<\/script>)/
  );
  if (!m) fail('could not find the JSON-LD block in index.html');
  let data;
  try {
    data = JSON.parse(m[2]);
  } catch (e) {
    fail(`the JSON-LD block is not valid JSON: ${e.message}`);
  }
  return { data, full: m[0], open: m[1], close: m[3] };
}

const nodeOfType = (graph, type) => graph.find((n) => n['@type'] === type);

/**
 * The English FAQ rich result must quote the English page verbatim. Nothing
 * generates that pair, so it is checked instead.
 */
function verifyEnglishFaq(jsonLd, faq) {
  const page = nodeOfType(jsonLd.data['@graph'], 'FAQPage');
  if (!page) fail('the JSON-LD graph has no FAQPage node');

  const drift = [];
  if (page.mainEntity.length !== faq.length) {
    drift.push(
      `${page.mainEntity.length} questions in JSON-LD vs ${faq.length} in the markup`
    );
  }
  faq.forEach(({ q, a }, i) => {
    const entry = page.mainEntity[i];
    if (!entry) return;
    if (entry.name !== q.en) {
      drift.push(`Q${i + 1} name:\n      JSON-LD: ${entry.name}\n      markup:  ${q.en}`);
    }
    const text = entry.acceptedAnswer?.text;
    if (text !== a.en) {
      drift.push(`Q${i + 1} answer:\n      JSON-LD: ${text}\n      markup:  ${a.en}`);
    }
  });

  if (drift.length) {
    fail(
      `the English FAQ structured data does not match the FAQ section.\n` +
        `  Google would show text the page does not contain. Fix the JSON-LD\n` +
        `  in website/index.html to quote the markup verbatim.\n\n    ` +
        drift.join('\n\n    ')
    );
  }
}

/** The Persian counterpart of the graph. */
function persianJsonLd(data, faq) {
  const graph = structuredClone(data['@graph']);

  // Each page publishes a self-consistent graph: the identifiers move under
  // /fa/ so the two documents never describe the same @id with different
  // text. Only the node ids and the page's own address move — an asset such
  // as the logo lives at the site root regardless of which page cites it.
  const walk = (node) => {
    for (const [k, v] of Object.entries(node)) {
      if (Array.isArray(v)) v.forEach((x) => x && typeof x === 'object' && walk(x));
      else if (v && typeof v === 'object') walk(v);
      else if (k === '@id' && typeof v === 'string' && v.startsWith(`${EN_URL}#`)) {
        node[k] = FA_URL + v.slice(EN_URL.length);
      } else if (k === 'url' && v === EN_URL) {
        node[k] = FA_URL;
      }
    }
  };
  graph.forEach(walk);

  const site = nodeOfType(graph, 'WebSite');
  if (site) {
    site.inLanguage = 'fa';
    site.description = FA.siteDescription;
  }

  const app = nodeOfType(graph, 'MobileApplication');
  if (app) {
    app.description = FA.appDescription;
    if (app.featureList) {
      if (app.featureList.length !== FA.featureList.length) {
        fail(
          `featureList has ${app.featureList.length} entries in index.html but ` +
            `${FA.featureList.length} Persian translations in this script`
        );
      }
      app.featureList = FA.featureList;
    }
  }

  const page = nodeOfType(graph, 'FAQPage');
  if (page) page.mainEntity = faqEntities(faq, 'fa');

  return { ...data, '@graph': graph };
}

/** Head, asset paths and the toggle: everything that differs per document. */
function localizeChrome(html, jsonLdBlock) {
  const swaps = [
    ['<html lang="en" dir="ltr">', '<html lang="fa" dir="rtl">'],

    [
      '<title>Tarkk — Walkie-talkie app with no internet needed</title>',
      `<title>${FA.title}</title>`,
    ],
    // The description and og:description share one string in the source, so
    // both matches are replaced.
    [
      /content="Tarkk is a walkie-talkie app that connects you directly to people nearby using WiFi or Bluetooth\. No internet or accounts required\."/g,
      `content="${FA.description}"`,
    ],
    [
      /<meta property="og:title" content="[^"]*">/,
      `<meta property="og:title" content="${FA.title}">`,
    ],
    [
      /<meta name="twitter:title" content="[^"]*">/,
      `<meta name="twitter:title" content="${FA.title}">`,
    ],
    [
      /<meta name="twitter:description"\s*\n?\s*content="[^"]*">/,
      `<meta name="twitter:description"\n    content="${FA.twitterDescription}">`,
    ],
    [
      /<meta property="og:image:alt" content="[^"]*">/,
      `<meta property="og:image:alt" content="${FA.imageAlt}">`,
    ],

    // The source comment is written from the English page's point of view.
    [
      /Each language is its own URL: English here[\s\S]*?and re-run the generator\./,
      `Each language is its own URL: Persian here, English at /, which is
       the source this page is generated from. Both carry the same hreflang
       set (each page names itself and its sibling) and a canonical pointing
       at itself, so the two rank separately instead of competing.

       Do not edit this file — change the data-fa attributes in
       ../index.html and re-run scripts/build-website-i18n.mjs.`,
    ],

    // Canonical points at this document; the hreflang trio is identical on
    // both pages and so passes through untouched.
    [`<link rel="canonical" href="${EN_URL}">`, `<link rel="canonical" href="${FA_URL}">`],
    [`<meta property="og:url" content="${EN_URL}">`, `<meta property="og:url" content="${FA_URL}">`],
    ['<meta property="og:locale" content="en_US">', '<meta property="og:locale" content="fa_IR">'],
    [
      '<meta property="og:locale:alternate" content="fa_IR">',
      '<meta property="og:locale:alternate" content="en_US">',
    ],

    // One directory down.
    ['href="styles.css"', 'href="../styles.css"'],
    ['src="app.js"', 'src="../app.js"'],
    ['href="favicon.ico"', 'href="../favicon.ico"'],
    ['href="logo.png"', 'href="../logo.png"'],

    // The toggle points back at English, and labels itself in English.
    [
      /<a id="langToggle" class="lang-toggle"[\s\S]*?<\/a>/,
      '<a id="langToggle" class="lang-toggle" href="/" hreflang="en" lang="en"\n' +
        '        aria-label="View in English">English</a>',
    ],
  ];

  let out = html;
  for (const [from, to] of swaps) {
    const before = out;
    out = out.replace(from, to);
    if (out === before) {
      fail(
        `nothing matched while localizing the head:\n    ${String(from).slice(0, 90)}\n` +
          `  index.html changed shape — update the swap list in this script.`
      );
    }
  }
  return out.replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>/, jsonLdBlock);
}

// ── Build ────────────────────────────────────────────────────────────
const check = process.argv.includes('--check');
const src = await readFile(SRC, 'utf8');

const faq = collectFaq(src);
const jsonLd = readJsonLd(src);
verifyEnglishFaq(jsonLd, faq);

const faJson = JSON.stringify(persianJsonLd(jsonLd.data, faq), null, 2)
  .split('\n')
  .map((line, i) => (i === 0 ? line : '  ' + line))
  .join('\n');

let out = translate(src, collectTranslatable(src));
out = localizeChrome(out, `${jsonLd.open}${faJson}${jsonLd.close}`);
out = out.replace(
  '<body>',
  '<body>\n\n  <!-- Generated from ../index.html by scripts/build-website-i18n.mjs.\n' +
    '       Do not edit: change the data-fa attributes in index.html and rebuild. -->'
);

// index.html is CRLF; the strings inserted above are not. Normalise to
// whatever the source uses so the generated file does not end up mixed.
const eol = src.includes('\r\n') ? '\r\n' : '\n';
out = out.replace(/\r\n/g, '\n').replace(/\n/g, eol);

if (check) {
  let current = null;
  try {
    current = await readFile(OUT, 'utf8');
  } catch (_) {}
  if (current !== out) {
    fail(
      'website/fa/index.html is out of date.\n' +
        '  Run: node scripts/build-website-i18n.mjs'
    );
  }
  console.log('website/fa/index.html is up to date');
} else {
  await mkdir(dirname(OUT), { recursive: true });
  await writeFile(OUT, out, 'utf8');
  console.log(
    `wrote website/fa/index.html — ${faq.length} FAQ entries, ` +
      `${collectTranslatable(src).filter((n) => n.fa).length} translated nodes`
  );
}
