// Renders the legal documents from website/legal/*.json.
//
//   legal/privacy.json → website/privacy.html  +  website/fa/privacy.html
//   legal/terms.json   → website/terms.html    +  website/fa/terms.html
//   both               → website/legal/index.json   (the version manifest)
//   both               → assets/legal/*.json        (the app's bundled copy)
//
//   node scripts/build-legal-pages.mjs
//   node scripts/build-legal-pages.mjs --check   (CI: verify, write nothing)
//
// WHY THE JSON IS THE SOURCE, and not the HTML it used to be:
//
// The Android app has to show these documents too — it asks people to accept
// them, and it may not show them a version it has not got. Two hand-kept
// copies of a privacy policy is exactly the arrangement where one of them
// quietly stops being true. So the text lives in one file, this script
// renders the web pages from it at build time, and the app fetches the same
// file over HTTP.
//
// Build time rather than in the browser, deliberately. The site's whole
// search arrangement is one pre-rendered URL per language (see
// build-website-i18n.mjs); fetching in the page would undo that, and a legal
// page that renders from JS shows an empty document until the request lands
// — and nothing at all when it fails. A policy that can fail to display is
// worse than a static one.
//
// The app ships with a copy of all of this, written to assets/legal/ by this
// same script. That is not a cache — it is what makes the consent gate work
// on a phone that has never had a connection, which for an off-grid
// walkie-talkie is the normal case rather than the edge one. The network
// only ever tells the app that a *newer* version exists; it is never what
// lets the app show a document at all.
//
// Both languages come out of the same document because the strings are
// stored as {en, fa} pairs rather than as two parallel trees. That is what
// makes a missing translation impossible to ship: there is one structure, and
// a language is either present at every node or the build stops.

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SITE = join(ROOT, 'website');
const LEGAL = join(SITE, 'legal');
const APP_ASSETS = join(ROOT, 'assets', 'legal');

const ORIGIN = 'https://tarkk.ir';
const DOCS = ['privacy', 'terms'];
const LANGS = ['en', 'fa'];

/** Shared with the landing page: one social image for the whole site. */
const OG_IMAGE_ALT = {
  en: 'Tarkk — talk instantly, no cell towers, no internet needed.',
  fa: 'تَرک — فوری حرف بزنید، بدون آنتن و بدون اینترنت.',
};

/** The bar's links, which live on the landing page rather than here. */
const NAV = [
  ['#features', { en: 'Features', fa: 'ویژگی‌ها' }],
  ['#handshake', { en: 'How it works', fa: 'چطور کار میکنه؟' }],
  ['#tech', { en: 'Details', fa: 'جزئیات بیشتر' }],
  ['#faq', { en: 'FAQ', fa: 'سوالات شما' }],
  ['#download', { en: 'Download', fa: 'دریافت' }],
];

const FOOTER = [
  ['#features', { en: 'Features', fa: 'ویژگی‌ها' }],
  ['#tech', { en: 'Details', fa: 'جزئیات بیشتر' }],
  ['#faq', { en: 'FAQ', fa: 'سوالات شما' }],
  ['#download', { en: 'Download', fa: 'دریافت' }],
];

const UI = {
  menu: { en: 'Menu', fa: 'منو' },
  anchor: { en: 'Link to this section', fa: 'پیوند به این بخش' },
  tagline: {
    en: 'Made for riders. Easy for everybody.',
    fa: 'طراحی شده برای موتورسوارها، راحت برای استفاده همه.',
  },
  privacy: { en: 'Privacy', fa: 'حریم خصوصی' },
  terms: { en: 'Terms', fa: 'شرایط' },
  toEnglish: { label: 'English', aria: 'View in English' },
  toPersian: { label: 'فارسی', aria: 'نمایش به فارسی' },
};

const fail = (msg) => {
  console.error(`\n  build-legal-pages: ${msg}\n`);
  process.exit(1);
};

// ── Text handling ────────────────────────────────────────────────────

/**
 * Reads one language out of an {en, fa} pair, and refuses to render a
 * document with a hole in it. A half-translated privacy policy is not a
 * cosmetic problem, so this is a build failure rather than a fallback to
 * English.
 */
function t(pair, lang, where) {
  if (pair == null) fail(`missing text at ${where}`);
  if (typeof pair === 'string') return pair; // deliberately language-neutral
  const v = pair[lang];
  if (typeof v !== 'string' || !v.trim()) {
    fail(`${where}: no "${lang}" translation`);
  }
  return v;
}

/** Escapes text for a text node. */
const esc = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** Escapes text for a double-quoted attribute value. */
const attr = (s) => esc(s).replace(/"/g, '&quot;');

// ── Blocks ───────────────────────────────────────────────────────────

function renderBlock(block, lang, where) {
  switch (block.type) {
    case 'p':
      return `        <p>${esc(t(block.text, lang, where))}</p>`;

    case 'h3':
      return `        <h3>${esc(t(block.text, lang, where))}</h3>`;

    case 'list':
      return [
        '        <ul class="legal-list">',
        ...block.items.map(
          (item) => `          <li>${esc(t(item, lang, `${where} item`))}</li>`
        ),
        '        </ul>',
      ].join('\n');

    case 'note':
      return [
        '        <div class="legal-note">',
        `          <b>${esc(t(block.label, lang, `${where} label`))}</b>`,
        `          <p>${esc(t(block.text, lang, where))}</p>`,
        '        </div>',
      ].join('\n');

    case 'rows':
      return [
        '        <div class="legal-rows">',
        ...block.items.map((item) => {
          // A row is titled either by a link (a brand, an address — the same
          // string in both languages) or by a translated label.
          const name = item.href
            ? `<a class="legal-row-name" href="${attr(item.href)}"` +
              (item.external ? ' rel="noopener" target="_blank"' : '') +
              `>${esc(item.name)}</a>`
            : `<b>${esc(t(item.name, lang, `${where} row name`))}</b>`;
          return [
            '          <div class="legal-row">',
            `            ${name}`,
            `            <p>${esc(t(item.text, lang, `${where} row text`))}</p>`,
            '          </div>',
          ].join('\n');
        }),
        '        </div>',
      ].join('\n');

    default:
      return fail(`${where}: unknown block type "${block.type}"`);
  }
}

// ── Document ─────────────────────────────────────────────────────────

function renderHead(doc, lang) {
  const other = lang === 'en' ? 'fa' : 'en';
  const self = ORIGIN + doc.webPath[lang];
  const rel = lang === 'fa' ? '../' : '';
  const faUrl = ORIGIN + doc.webPath.fa;

  return `<!DOCTYPE html>
<html lang="${lang}" dir="${lang === 'fa' ? 'rtl' : 'ltr'}">

<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
  <title>${esc(t(doc.meta.title, lang, 'meta.title'))}</title>
  <meta name="description" content="${attr(t(doc.meta.description, lang, 'meta.description'))}">
  <meta name="theme-color" content="#0B0E11">

  <!-- ── Search ───────────────────────────────────────────────────────
       Each language is its own URL, carrying the same hreflang set (each
       page names itself and its sibling) and a canonical pointing at
       itself, so the two rank separately instead of competing. x-default
       is the Persian page, for the reason index.html spells out: Tarkk is
       built for an Iranian audience. -->
  <link rel="canonical" href="${self}">
  <link rel="alternate" hreflang="en" href="${ORIGIN}${doc.webPath.en}">
  <link rel="alternate" hreflang="fa" href="${faUrl}">
  <link rel="alternate" hreflang="x-default" href="${faUrl}">
  <meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1">
  <link rel="icon" href="${rel}favicon.ico" sizes="any">
  <link rel="apple-touch-icon" href="${rel}logo.png">

  <!-- ── Link previews ───────────────────────────────────────────────── -->
  <meta property="og:type" content="article">
  <meta property="og:site_name" content="Tarkk">
  <meta property="og:url" content="${self}">
  <meta property="og:title" content="${attr(t(doc.meta.title, lang, 'meta.title'))}">
  <meta property="og:description" content="${attr(t(doc.meta.description, lang, 'meta.description'))}">
  <meta property="og:image" content="${ORIGIN}/og-image.png">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:alt" content="${attr(OG_IMAGE_ALT[lang])}">
  <meta property="og:locale" content="${lang === 'fa' ? 'fa_IR' : 'en_US'}">
  <meta property="og:locale:alternate" content="${lang === 'fa' ? 'en_US' : 'fa_IR'}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${attr(t(doc.meta.title, lang, 'meta.title'))}">
  <meta name="twitter:description" content="${attr(t(doc.meta.twitterDescription, lang, 'meta.twitterDescription'))}">
  <meta name="twitter:image" content="${ORIGIN}/og-image.png">

  <!-- ── Inline scripts ───────────────────────────────────────────────
       Above the stylesheet links for the reason spelled out in index.html:
       an inline script waits for every sheet requested before it, so
       putting these after the jsdelivr link hands a third-party CDN the
       power to stall parsing of the whole document. -->

  <!-- iOS gets a native-style navigation bar (styles.css). Set here rather
       than in app.js so the bar is never painted in its desktop form for a
       frame first. -->
  <script>
    if (window.CSS && CSS.supports && CSS.supports('-webkit-touch-callout', 'none')) {
      document.documentElement.classList.add('is-ios');
    }
  </script>
${
  lang === 'en'
    ? `
  <!-- ── Language routing ─────────────────────────────────────────────
       The same rule as the landing page, pointed at this document's
       Persian twin: Persian is the site, and the only way to stay on the
       English copy is to have asked for English with the toggle, which
       writes tark_lang. See index.html for the full reasoning, including
       what this costs in English search presence. Only rendered into the
       English document, so no loop is possible. -->
  <script>
    (function () {
      if (document.documentElement.lang !== 'en') return;
      var want = null;
      try { want = localStorage.getItem('tark_lang'); } catch (_) {}
      if (want !== 'en') location.replace('${doc.webPath.fa}');
    })();
  </script>
`
    : ''
}
  <link rel="preconnect" href="https://cdn.jsdelivr.net" crossorigin>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/vazirmatn@33.0.3/Vazirmatn-font-face.css">
  <link rel="stylesheet" href="${rel}styles.css">
</head>`;
}

function renderNav(doc, lang) {
  const home = lang === 'fa' ? '/fa/' : '/';
  const toggle =
    lang === 'en'
      ? { href: doc.webPath.fa, lang: 'fa', ...UI.toPersian }
      : { href: doc.webPath.en, lang: 'en', ...UI.toEnglish };

  return `  <!-- ── Nav ─────────────────────────────────────────────────────────
       The same bar as the landing page, with its links pointed back at it.
       app.js is shared across the site and skips the blocks whose elements
       are not on this page. -->
  <nav id="nav">
    <div class="nav-inner">
      <a class="wordmark" href="${home}">
        <span class="wordmark-dot"></span>TARKK
      </a>
      <div class="nav-links" id="navLinks">
${NAV.map(
  ([hash, label]) =>
    `        <a href="${home}${hash}">${esc(label[lang])}</a>`
).join('\n')}
      </div>
      <a id="langToggle" class="lang-toggle" href="${toggle.href}" hreflang="${toggle.lang}"
        lang="${toggle.lang}" aria-label="${attr(toggle.aria)}">${esc(toggle.label)}</a>
      <button id="menuToggle" class="menu-toggle" aria-expanded="false" aria-controls="navLinks">
        <span class="menu-icon" aria-hidden="true"></span>
        <span class="sr-only">${esc(UI.menu[lang])}</span>
      </button>
    </div>
  </nav>`;
}

function renderBody(doc, lang) {
  const home = lang === 'fa' ? '/fa/' : '/';
  const anchorLabel = esc(UI.anchor[lang]);

  const sections = doc.sections
    .map((sec, i) => {
      const where = `${doc.id} §${i + 1} (${sec.id})`;
      return `      <!-- ── ${i + 1} ───────────────────────────────────────────────────── -->
      <section class="legal-sec reveal" id="${attr(sec.id)}">
        <h2>
          <span>${esc(t(sec.title, lang, `${where} title`))}</span>
          <a class="legal-anchor" href="#${attr(sec.id)}"><span class="sr-only">${anchorLabel}</span></a>
        </h2>
${sec.blocks.map((b, j) => renderBlock(b, lang, `${where} block ${j + 1}`)).join('\n')}
      </section>`;
    })
    .join('\n\n');

  return `<body>

${renderNav(doc, lang)}

  <!-- ── Hero ────────────────────────────────────────────────────────── -->
  <header class="legal-hero">
    <i class="legal-sweep" aria-hidden="true"></i>
    <div class="legal-hero-inner">
      <p class="eyebrow reveal-up">${esc(t(doc.hero.eyebrow, lang, 'hero.eyebrow'))}</p>
      <h1 class="legal-title reveal-up d1">${esc(t(doc.hero.heading, lang, 'hero.heading'))}</h1>
      <p class="legal-lede reveal-up d2">${esc(t(doc.hero.lede, lang, 'hero.lede'))}</p>
      <div class="legal-meta reveal-up d3">
        <span class="legal-stamp">
          <i aria-hidden="true"></i>
          <span>${esc(t(doc.hero.inEffectSince, lang, 'hero.inEffectSince'))}</span>
          <b><time datetime="${attr(doc.effectiveDate)}">${esc(
    t(doc.effectiveDateLabel, lang, 'effectiveDateLabel')
  )}</time></b>
        </span>
        <a class="legal-swap" href="${attr(doc.hero.swap.href)}">${esc(
    t(doc.hero.swap.label, lang, 'hero.swap')
  )}</a>
      </div>
    </div>
  </header>

  <div class="legal-shell">

    <!-- data-native-scroll: below 980px this rail scrolls sideways, and the
         page's eased-wheel handler hands any subtree carrying this
         attribute straight back to the browser. -->
    <aside class="legal-toc" data-native-scroll>
      <p class="legal-toc-title">${esc(t(doc.contentsLabel, lang, 'contentsLabel'))}</p>
      <ol>
${doc.sections
  .map(
    (sec) =>
      `        <li><a href="#${attr(sec.id)}">${esc(
        t(sec.tocTitle, lang, `toc ${sec.id}`)
      )}</a></li>`
  )
  .join('\n')}
      </ol>
    </aside>

    <main class="legal-main">

      <!-- ── The short version ────────────────────────────────────────
           The landing page's ledger, reused: it is answering the same
           question one level deeper. -->
      <section class="legal-summary">
        <div class="ledger">
${doc.summary.columns
  .map(
    (col) => `          <div class="ledger-col reveal">
            <p class="ledger-title">${esc(t(col.title, lang, 'summary title'))}</p>
            <ul class="ledger-list ${col.kind}">
${col.items
  .map((item) => `              <li>${esc(t(item, lang, 'summary item'))}</li>`)
  .join('\n')}
            </ul>
          </div>`
  )
  .join('\n')}
        </div>
      </section>

${sections}

      <!-- ── The other document ──────────────────────────────────────── -->
      <div class="legal-cross reveal">
${doc.cross
  .map((card) => {
    // "/#download" has to follow the reader into /fa/; a sibling document is
    // a relative href and already resolves in the right directory.
    const href = card.href.startsWith('/#') ? home + card.href.slice(1) : card.href;
    return `        <a href="${attr(href)}">
          <span class="legal-cross-kicker">${esc(t(card.kicker, lang, 'cross kicker'))}</span>
          <span class="legal-cross-title">${esc(t(card.title, lang, 'cross title'))}</span>
          <span class="legal-cross-sub">${esc(t(card.sub, lang, 'cross sub'))}</span>
        </a>`;
  })
  .join('\n')}
      </div>

    </main>
  </div>

  <footer>
    <span class="wordmark"><span class="wordmark-dot"></span>TARKK</span>
    <div class="footer-links">
${FOOTER.map(
  ([hash, label]) => `      <a href="${home}${hash}">${esc(label[lang])}</a>`
).join('\n')}
      <a href="privacy.html">${esc(UI.privacy[lang])}</a>
      <a href="terms.html">${esc(UI.terms[lang])}</a>
    </div>
    <p>${esc(UI.tagline[lang])}</p>
  </footer>

  <script src="${lang === 'fa' ? '../' : ''}app.js"></script>
</body>

</html>
`;
}

const banner = (id) =>
  `\n  <!-- Generated from website/legal/${id}.json by scripts/build-legal-pages.mjs.\n` +
  `       Do not edit this file — change the JSON and rebuild. -->\n`;

function renderDocument(doc, lang) {
  const body = renderBody(doc, lang).replace('<body>\n', `<body>\n${banner(doc.id)}`);
  return `${renderHead(doc, lang)}\n\n${body}`;
}

// ── Validation ───────────────────────────────────────────────────────

/**
 * Everything that has to be true before a document is worth rendering. The
 * cost of a bad legal page is not a broken layout, it is a claim nobody
 * checked, so these are refusals rather than warnings.
 */
function validate(doc) {
  const where = `legal/${doc.id}.json`;
  if (doc.schema !== 1) fail(`${where}: unknown schema ${doc.schema}`);
  if (!Number.isInteger(doc.version) || doc.version < 1) {
    fail(`${where}: version must be a positive integer`);
  }
  if (
    !Number.isInteger(doc.minAcceptedVersion) ||
    doc.minAcceptedVersion < 1 ||
    doc.minAcceptedVersion > doc.version
  ) {
    fail(
      `${where}: minAcceptedVersion must be between 1 and version (${doc.version}); ` +
        `got ${doc.minAcceptedVersion}`
    );
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(doc.effectiveDate)) {
    fail(`${where}: effectiveDate must be YYYY-MM-DD`);
  }
  if (!doc.sections?.length) fail(`${where}: no sections`);

  const ids = new Set();
  for (const sec of doc.sections) {
    if (!sec.id) fail(`${where}: a section has no id`);
    if (ids.has(sec.id)) fail(`${where}: duplicate section id "${sec.id}"`);
    ids.add(sec.id);
    if (!sec.blocks?.length) fail(`${where}: section "${sec.id}" has no blocks`);
  }

  // Both languages, everywhere. t() enforces this while rendering; doing it
  // here as well means the failure names the document rather than whichever
  // page happened to be rendered first.
  for (const lang of LANGS) renderBody(doc, lang);
}

// ── Build ────────────────────────────────────────────────────────────

const check = process.argv.includes('--check');
let stale = 0;

/** Writes one generated file, or under --check reports it as stale. */
async function emitAt(path, contents, label) {
  if (check) {
    let current = null;
    try {
      current = await readFile(path, 'utf8');
    } catch (_) {}
    if (current !== contents) {
      console.error(`  ${label} is out of date`);
      stale += 1;
    }
    return;
  }
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, contents, 'utf8');
}

async function emit(relPath, contents) {
  const path = join(SITE, relPath);
  if (check) {
    let current = null;
    try {
      current = await readFile(path, 'utf8');
    } catch (_) {}
    if (current !== contents) {
      console.error(`  website/${relPath} is out of date`);
      stale += 1;
    }
    return;
  }
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, contents, 'utf8');
}

const manifest = {
  schema: 1,
  // Regenerated from the documents, never hand-written: a manifest that can
  // disagree with the file it describes is worse than no manifest, because
  // the app trusts it to decide whether to ask for consent again.
  generated: 'scripts/build-legal-pages.mjs',
  documents: [],
};

for (const id of DOCS) {
  const raw = await readFile(join(LEGAL, `${id}.json`), 'utf8');
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (e) {
    fail(`legal/${id}.json is not valid JSON: ${e.message}`);
  }
  if (doc.id !== id) fail(`legal/${id}.json declares id "${doc.id}"`);
  validate(doc);

  for (const lang of LANGS) {
    const out = renderDocument(doc, lang);
    await emit(lang === 'fa' ? `fa/${id}.html` : `${id}.html`, out);
  }

  manifest.documents.push({
    id: doc.id,
    name: doc.name,
    version: doc.version,
    minAcceptedVersion: doc.minAcceptedVersion,
    effectiveDate: doc.effectiveDate,
    file: `${id}.json`,
    webPath: doc.webPath,
  });

  // The app's copy is the same bytes, not a re-serialisation: an asset that
  // differs from the file the app will later download — even by key order —
  // turns "is this newer?" into a question about formatting.
  await emitAt(join(APP_ASSETS, `${id}.json`), raw, `assets/legal/${id}.json`);

  if (!check) {
    console.log(
      `${id}: v${doc.version} (min accepted v${doc.minAcceptedVersion}), ` +
        `${doc.sections.length} sections → 2 pages + 1 asset`
    );
  }
}

const manifestJson = JSON.stringify(manifest, null, 2) + '\n';
await emitAt(join(LEGAL, 'index.json'), manifestJson, 'website/legal/index.json');
await emitAt(join(APP_ASSETS, 'index.json'), manifestJson, 'assets/legal/index.json');

if (check) {
  if (stale) {
    fail(`${stale} generated file(s) out of date.\n  Run: node scripts/build-legal-pages.mjs`);
  }
  console.log('legal pages, manifest and app assets are up to date');
} else {
  console.log('wrote website/legal/index.json and assets/legal/');
}
