import { readFile, readdir } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const copyDirectories = [
  'lib',
  'assets',
  'backend/internal',
  'android/app/src',
  'ios/Runner',
  'ios/TarkWidget',
  'macos/Runner',
  'web',
  'website',
];
const authoringFiles = [
  'docs/bazaar-screenshots/README.md',
  'scripts/bazaar-assets/capture_test.dart',
  'scripts/build-legal-pages.mjs',
  'scripts/website-loader.html',
];
const textExtensions = new Set([
  '.arb', '.css', '.dart', '.go', '.html', '.js', '.json', '.kt', '.mjs',
  '.plist', '.strings', '.svg', '.swift', '.xml',
]);
const ignoredDirectories = new Set(['build', 'node_modules', 'vendor']);
const markupExtensions = new Set(['.html', '.svg', '.xml', '.plist']);
const jsonExtensions = new Set(['.arb', '.json']);
// Includes the precomposed ezafe used after heh. NFKC handles presentation forms.
const hamza = /[\u0621\u0623-\u0626\u0654\u0655\u065f\u0672-\u0678\u0681\u06c0\u06c2\u06d3\u076c\u0881-\u0883\u08a1\u08a8]/u;
const failures = [];

function decodeMarkupReferences(line) {
  return line.replace(/&#(x[0-9a-f]+|\d+);?/gi, (reference, digits) => {
    const hexadecimal = /^[xX]/.test(digits);
    const codePoint = hexadecimal ? parseInt(digits.slice(1), 16) : Number(digits);
    return codePoint <= 0x10ffff ? String.fromCodePoint(codePoint) : reference;
  });
}

async function checkFile(path) {
  const source = await readFile(join(root, path), 'utf8');
  const extension = extname(path);
  for (const [index, line] of source.split(/\r?\n/).entries()) {
    let copy = line;
    if (markupExtensions.has(extension)) copy = decodeMarkupReferences(copy);
    if (jsonExtensions.has(extension)) {
      copy = copy.replace(/\\(?:u([0-9a-f]{4})|.)/gi, (escape, hex) =>
        hex ? String.fromCharCode(parseInt(hex, 16)) : escape,
      );
    }
    if (hamza.test(copy.normalize('NFKC'))) failures.push(path + ':' + (index + 1));
  }
}

async function checkDirectory(path) {
  const entries = await readdir(join(root, path), { withFileTypes: true });
  for (const entry of entries) {
    const child = path + '/' + entry.name;
    if (entry.isDirectory() && !ignoredDirectories.has(entry.name)) {
      await checkDirectory(child);
    } else if (entry.isFile() && textExtensions.has(extname(entry.name)) && !/_test\.(dart|go)$/.test(entry.name)) {
      await checkFile(child);
    }
  }
}

for (const directory of copyDirectories) await checkDirectory(directory);
for (const file of authoringFiles) await checkFile(file);

if (failures.length) {
  console.error('Hamza found in product copy. Use a spelling without hamza.');
  for (const failure of failures) console.error(failure);
  process.exitCode = 1;
} else {
  console.log('Persian product copy passed the hamza check.');
}
