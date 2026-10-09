# Tarkk social images

Generated with the built-in imagegen tool. Both images are delivered at 1200 × 630 pixels.

- Persian: `website/og-image.png`, right-aligned Persian text and photography on the left.
- English: `website/og-image-en.png`, left-aligned English text and photography on the right. The phone interface and logo retain their correct orientation.

Persian reference images: `website/assets/tarkk-ride.webp` (current website hero) and `website/logo.png` (brand identity).
English reference images: `website/og-image.png` (Persian counterpart) and `website/logo.png` (brand identity).

Landing and legal pages select their image in the initial HTML using `SITE_META` in `scripts/website-shared.mjs`. Share a `/fa/` URL for the Persian preview or its English sibling for the English preview; a browser language preference does not select a different preview for the same shared URL.

## Persian final prompt

Use case: ads-marketing
Asset type: one finished landscape Open Graph / social link-preview image for Tarkk, matching the CURRENT website. Target aspect ratio 1200:630 (1.90476:1), edge-to-edge horizontal composition, preferably 1200 x 630 pixels.
Primary request: redesign the previous generic orange radio-rings share image into a premium, warm, forest-green photographic brand image that visually belongs to the new Tarkk landing page.
Input images: Image 1 is the current hero photograph, a scene/material/composition reference. Image 2 is the actual Tarkk orange logo, a logo identity reference. Make a fresh complete advertising image; do not reproduce a website screenshot or browser chrome.

Scene/backdrop: believable pre-ride preparation tabletop, worn olive/forest-green canvas and warm natural timber. A large black Android phone rests slightly diagonally in portrait orientation on the LEFT half, a cropped matte black motorcycle helmet at upper left, black riding gloves with restrained orange stitching at lower left, and a subtle wired helmet audio earpiece beside the phone. Keep props and the phone natural, grounded and physically coherent, inspired by the supplied hero photo. Phone display should resemble the real supplied Tarkk UI: charcoal screen, small TARKK branding, green circular voice activity visualizer, restrained member rows and microphone control; crisp recognizable display but no busy tiny invented text. No human figures.

Composition: the full left 52% is photographic product scene. On the right, let the same continuous photo fall naturally into a deep forest-green shadow/scrim, #0D1913 / #17271D, leaving generous quiet room for clean Persian editorial typography. Seamless transition, not two boxed panels. All branding and important text are within a safe 55px equivalent inset from all image edges. Use sparse, bold typesetting with ample breathing room. Avoid poster density or extra UI components. The phone and scene should remain large and recognizable in a small social preview.

Typography and exact text: Persian letters MUST be correctly shaped, joined and right-to-left, as in Vazirmatn ExtraBold; no calligraphic styling. Top-right brand lockup: the reference's exact orange angular T logo beside the word "TARKK" in small bold warm ivory sans serif. Main headline on the right, large and right aligned, exactly two stacked lines:
"هم‌مسیر،"
"هم‌صدا."
First headline line warm ivory #F2F3E9, second line orange #F5853F / #FF9652. The comma and full stop are required. Under the headline, one comfortably readable short supporting Persian line or two if needed, verbatim:
"بیسیم گوشی به گوشی، حتی بدون اینترنت."
At the bottom right in restrained small ivory typography:
"Bluetooth · Wi-Fi · Hotspot"
At the bottom left or below the supporting copy, use the exact website address "tarkk.ir", small yet clearly legible.
No other marketing text or CTA buttons.

Light and mood: premium editorial commercial photography, warm low-angle afternoon daylight, subtle natural textures and soft grounded shadows. Restrained amber timber, forest greens, charcoal, warm ivory and orange accents, a small green voice indicator on the phone. The overall piece is calm, tactile and confident, consistent with the website rather than neon cyberpunk.
Constraints: correct reference logo geometry; no old orange concentric rings, no cell towers, no abstract signal effects in the scene, no floating objects, no sci-fi holograms, no unrelated brands, no watermarks, no frames, no browser UI, no QR codes, no fake website screenshot. Deliver one polished production-ready horizontal social card.

## English final prompt

Use case: text-localization
Asset type: English-language counterpart of the supplied finished Tarkk social-preview image.
Input images: Image 1 is the Persian edit target / exact visual identity reference. Image 2 is the original logo identity reference.
Primary request: create a coordinated English version of Image 1 with the COMPOSITION DIRECTION reversed for left-to-right reading. This must look like the other language edition of the SAME campaign, keeping its forest-green scrim, timber, olive canvas, warm afternoon light, charcoal phone, orange and ivory colors, logo identity, close-up gear photography, print-clean bold type and high quality.

Composition: landscape aspect ratio 1200:630, approximately 1.90476:1. LEFT 48% is calm dark forest green (#0D1913 / #17271D) typography zone; RIGHT 52% is the photograph. Re-stage the gear to the right: large slightly angled portrait Android phone on olive canvas, cropped helmet at the upper-right and gloves with orange stitching at the lower-right, wired helmet earpiece naturally beside phone, tactile warm wood linking the full scene. Keep the phone physically believable and sharply defined. NOT a blind horizontal mirror of any letters, logo or UI. All lettering and the logo must remain correctly oriented. No fake signal rings or sci-fi effects. No people.

Typography: clean English Arial-like heavy sans serif, LEFT ALIGNED throughout. Match the scale and restraint of the supplied Persian card. Top LEFT brand lockup: exact reference's orange angular T logo followed by "TARKK" in warm ivory. Do not mirror the orange logo.
Large headline on left in TWO lines, verbatim:
"Same road."
"Stay close."
First headline line warm ivory #F2F3E9; second line orange #F5853F / #FF9652.
Under headline, smaller comfortably readable supporting text, exactly:
"Phone-to-phone voice."
"Even off-grid."
Bottom of left typography zone, the exact label "Bluetooth · Wi-Fi · Hotspot", and exact address "tarkk.ir". Keep all main content within 50px equivalent safe inset. No Persian or Arabic text anywhere in this English image.

Phone UI: charcoal Tarkk channel screen adapted to ENGLISH left-to-right display, with normal correctly oriented small "TARKK", familiar green circular voice visualizer, microphone row and two member rows. Use "Pedram" and "Nazanin" for member names if legible. The green center may say "Nazanin". Do not mirror any UI text; do not reflect the logo. Keep UI subordinate and visually consistent with the actual app in the supplied target.
Constraints: preserve the same photographic style, materials, lighting and palette as Image 1. Keep real logo geometry. Only language and composition direction change. No additional ads, copy, browser chrome, CTA buttons, watermarks, QR codes, borders, extra panels or arbitrary symbols. Deliver one polished finished horizontal English social image, target 1200 x 630 pixels.

### English UI correction prompt

Use case: precise-object-edit
Edit target: supplied English Tarkk social image.
Make ONLY a small correction to the visible phone UI text. Keep the entire banner composition, exact English main headline ("Same road." / "Stay close."), brand lockup, supporting copy, address, colors, lighting, photo, phone position, helmet, gloves and all surrounding pixels visually unchanged.
The real Tarkk app is an open voice channel with a mic toggle, not a hold-to-talk app.
In the phone's existing microphone control row below the green circular visualizer, replace "Tap to Speak" with "MIC LIVE"; replace "Hold to talk on this channel" with "The channel can hear you". Keep the microphone icon and row dimensions as they are.
In the Nazanin member row below, replace the gray dot and "Offline" with a GREEN dot and "Talking", matching the fact that Nazanin is active in the green visualizer. Keep "Nazanin", "Pedram", the other row and avatars.
Do not re-layout the advertisement, do not flip anything, do not add any new UI or copy, keep every other part of the image. Target landscape 1200:630 aspect ratio.
