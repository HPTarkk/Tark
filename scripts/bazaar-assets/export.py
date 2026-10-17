"""Encode rendered boards as small, full-resolution JPGs and package them.

Requires Pillow. Run after capture_test.dart:
    python scripts/bazaar-assets/export.py
"""
from io import BytesIO
from pathlib import Path
import json
import zipfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'build' / 'bazaar-assets'
TARGET = ROOT / 'docs' / 'bazaar-screenshots'
FILES = [
    '01-offline', '02-voice', '03-rooms',
    '04-connect', '05-settings', '06-light',
]


def main():
    TARGET.mkdir(parents=True, exist_ok=True)
    manifest = []
    for stem in FILES:
        with Image.open(SOURCE / f'{stem}.png') as source:
            assert source.size == (1080, 1920), source.size
            image = source.convert('RGB')
            for quality in range(94, 69, -1):
                buffer = BytesIO()
                # Full chroma resolution protects small orange/green UI text.
                image.save(buffer, format='JPEG', quality=quality,
                           subsampling=0, optimize=True, progressive=True)
                encoded = buffer.getvalue()
                if len(encoded) <= 280_000:
                    break
            if len(encoded) > 280_000:
                raise ValueError(f'{stem} exceeds the 280 KB size budget')
            path = TARGET / f'{stem}.jpg'
            path.write_bytes(encoded)
            with Image.open(path) as check:
                check.verify()
            manifest.append({'file': path.name, 'width': 1080, 'height': 1920,
                             'bytes': len(encoded), 'quality': quality})
    (TARGET / 'manifest.json').write_text(
        json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    capture = json.loads((SOURCE / 'capture.json').read_text(encoding='utf-8'))
    (TARGET / 'capture.json').write_text(
        json.dumps(capture, indent=2) + '\n', encoding='utf-8')
    (TARGET / '05-riding.jpg').unlink(missing_ok=True)
    archive = TARGET / 'tark-bazaar-screenshots.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
        for item in manifest:
            bundle.write(TARGET / item['file'], item['file'])
        bundle.write(TARGET / 'README.md', 'README.md')
        bundle.write(TARGET / 'manifest.json', 'manifest.json')
        bundle.write(TARGET / 'capture.json', 'capture.json')
    print(json.dumps({'images': manifest, 'zip_bytes': archive.stat().st_size}, indent=2))


if __name__ == '__main__':
    main()
