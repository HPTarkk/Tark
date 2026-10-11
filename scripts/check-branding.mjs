// Guard public brand copy while leaving repository paths, package IDs and
// transport compatibility identifiers alone. Run after the website generators.
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = path => readFile(join(root, path), 'utf8');
const json = async path => JSON.parse(await read(path));
// Canonical prose uses Tarkk; uppercase wordmarks are a permitted style.
const brandSpellings = new Set(['Tarkk', 'TARKK']);
let checked = 0;
function checkCopy(text, location) {
  // GitHub's repository slug and the installed package intentionally use Tark
  // / tark. Neither is a public spelling error. Decode email subjects too.
  try { text = decodeURIComponent(text); } catch {}
  text = text.replace(/https?:\/\/[^\s"'<>]+/g, '');
  text = text.replace(/github\.com\/[^\s"'<>]+/g, '');
  // The iOS URL scheme is a compatibility identifier, not displayed copy.
  text = text.replace(/<string>tark<\/string>/g, '');
  const names = text.match(/(?<![./_-])\b(?:tark|tarkk|wakitaki)\b(?![./_-]|:\/\/)/gi) ?? [];
  assert(names.every(name => brandSpellings.has(name)), `Wrong app name in ${location}`);
  checked++;
}
function strings(value, location) {
  if (typeof value === 'string') return checkCopy(value, location);
  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) strings(child, `${location}.${key}`);
  }
}

const en = await json('lib/core/l10n/app_en.arb');
assert.equal(en.app_name, 'Tarkk');
assert.equal((await json('lib/core/l10n/app_fa.arb')).app_name, 'تَرک');
strings(en, 'English app localization');
strings(await json('web/manifest.json'), 'Guest web manifest');
for (const name of ['privacy', 'terms', 'delete-account']) {
  strings(await json(`website/legal/${name}.json`), `Legal ${name}`);
}
for (const dir of ['website', 'website/fa', 'website/v']) {
  for (const entry of await readdir(join(root, dir), { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith('.html')) {
      const path = `${dir}/${entry.name}`;
      const html = await read(path);
      checkCopy(html.replace(/<script\b[\s\S]*?<\/script>/gi, ''), path);
    }
  }
}
checkCopy(await read('web/index.html'), 'Guest web shell');
checkCopy(await read('website/app-ui.js'), 'Interactive website app screens');
checkCopy(await read('scripts/website-loader.html'), 'Website loading copy');
for (const file of ['templates.go', 'html.go']) {
  checkCopy(await read(`backend/internal/mail/${file}`), `Backend mail ${file}`);
}
for (const path of ['backend/internal/billing/plans.go', 'backend/internal/i18n/messages.go']) {
  checkCopy(await read(path), path);
}
for (const path of ['ios/Runner/Info.plist', 'ios/TarkWidget/Info.plist',
  'ios/TarkWidget/TarkWidget.swift', 'ios/TarkWidget/SharedState.swift', 'macos/Runner/Info.plist']) {
  checkCopy(await read(path), path);
}
for (const platform of ['windows/runner/main.cpp', 'linux/runner/my_application.cc']) {
  assert((await read(platform)).includes('"Tarkk"'), `Wrong window title in ${platform}`);
}
for (const [folder, name] of [['values', 'Tarkk'], ['values-fa', 'تَرک']]) {
  const source = await read(`android/app/src/main/res/${folder}/strings.xml`);
  for (const key of ['app_name', 'widget_app_name']) {
    assert(source.includes(`<string name="${key}">${name}</string>`), `${folder}: ${key}`);
  }
}
for (const path of ['audio/SystemAudioCaptureService.kt', 'keepalive/SessionKeepAliveService.kt']) {
  const source = await read(`android/app/src/main/kotlin/com/b1101/tark/${path}`);
  assert(source.includes('.setContentTitle(getString(R.string.app_name))'), `Unlocalized notification: ${path}`);
}
console.log(`Brand copy checked: ${checked} strings/surfaces; English Tarkk (TARKK wordmarks allowed), Persian تَرک.`);
