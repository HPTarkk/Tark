"""Rebuild the tiny inline loader fonts when its Persian copy changes.

Requires fonttools and brotli only for this optional asset-authoring step.
Normal website builds consume the checked-in WOFF2 data in loader-fonts.json.
"""
import base64
import io
import json
import re
from pathlib import Path
from fontTools import subset
from fontTools.ttLib import TTFont

root = Path(__file__).resolve().parent.parent
markup = (root / 'scripts/website-loader.html').read_text(encoding='utf-8')
copy = ' '.join(re.findall(r'data-fa="([^"]+)"', markup)) + ' ۰۱۲۳۴۵۶۷۸۹٪'
fonts = {}
for weight, filename, text in [
    (500, 'Vazirmatn-Medium.woff2', copy),
    (900, 'Vazirmatn-Black.ttf', 'تَرک'),
]:
    font = TTFont(root / 'website/assets' / filename)
    options = subset.Options()
    options.layout_features = ['*']  # Keep Persian shaping and mark positioning.
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    worker = subset.Subsetter(options=options)
    worker.populate(text=text)
    worker.subset(font)
    for record in font['name'].names:
        if record.nameID in (1, 3, 4, 6):
            record.string = f'TarkkLoader-{weight}'.encode(record.getEncoding())
    font.flavor = 'woff2'
    output = io.BytesIO()
    font.save(output)
    data = output.getvalue()
    fonts[str(weight)] = base64.b64encode(data).decode('ascii')
    print(f'Loader weight {weight}: {len(data)} bytes')
(root / 'scripts/loader-fonts.json').write_text(json.dumps(fonts) + '\n', encoding='utf-8')
