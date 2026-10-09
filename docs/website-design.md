# Tarkk website design handoff

Approved design source: `website/` in `D:/Dev/wakitaki`.
Original review sandbox: `D:/Dev/tarkk-cinematic-preview`.
The website is plain static HTML/CSS/JavaScript, with localized `/` and `/fa/` pages.

## Forest palette

| Token | Hex | Use |
|---|---|---|
| `--bg` | `#0D1913` | Dark page background |
| `--surface` | `#17271D` | Secondary surface, hero footer |
| `--card` | `#213529` | Raised surface |
| `--line` | `#304538` | Dark separators |
| `--text` | `#F2F3E9` | Primary text |
| `--muted` | `#A7B3A8` | Supporting dark-surface text |
| `--paper` | `#EDF0E6` | Light editorial sections |
| `--ink` | `#1B2D21` | Text on paper |
| `--paper-muted` | `#647062` | Supporting paper text |
| `--paper-line` | `#CDD7C6` | Paper separators |
| `--accent` | `#F5853F` | Calls to action and active states |

Source of the forest tokens: `website/scene.css`. `website/styles.css` supplies the base design system; `website/polish.css` supplies responsive geometry and Persian typography. The embedded app demo still uses the app's original charcoal palette in `app-ui.css`. When applying the forest palette to Flutter, replace semantic theme surfaces consistently rather than tinting individual screens. Keep microphone self/peer signal colors distinct from the surface palette.

## Typography and motion

Persian uses locally hosted Vazirmatn with actual 400, 500, 600, 700, 800 and 900 font files. Supporting Persian copy is primarily 500; small marketing notes are at least 13px. English keeps the approved Arial typography. Numerals and alignment follow the language.

The Persian opening loader uses two tiny, shaping-preserving WOFF2 subsets embedded in the initial HTML (about 8.4 KB total). It never waits for an external font download or displays fallback type. The same font covers document exit/entry. If its Persian text changes, regenerate `scripts/loader-fonts.json` with `python scripts/build-loader-fonts.py` (authoring dependencies: fonttools and brotli); regular site builds need only Node.js. Full-page fonts stay unchanged.

`scene.js` controls the photo/live-app hero and opening sequence. `app.js` controls the landing demos. `motion.js` performs outgoing text fade, commits the replacement while hidden, then fades in the new text. `page-transitions.js` handles document navigation and history restoration; `legal-page.js` supplies the lighter legal-page behavior. Same-page anchors are handled separately. The email-link fallback deliberately has no JavaScript.

## Content and SEO

Edit layout and bilingual attributes in `website/index.html`; run `node scripts/build-website-i18n.mjs`. FAQ content and JSON-LD come from the same `content.js` source. Legal copy remains in `website/legal/*.json`; regenerate with `node scripts/build-legal-pages.mjs`. Run `node scripts/check-website.mjs` before publishing.

English and Persian have independent static content, canonical URLs, hreflang and localized metadata. A fresh visitor receives the language of the requested URL; an explicit stored Persian choice can redirect English URLs. Legal canonicals use the existing host's final extensionless URLs. The site uses no analytics, tracking cookies or third-party font requests.

Deploy the full `website/` directory using `wrangler.website.jsonc`. Do not omit the update feed, legal manifest or Android App Links files. The guest web app has a separate host and deployment.
