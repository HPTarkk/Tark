"""Builds the admin panel's Persian-digit fonts.

The panel keeps numbers as Latin digits in the HTML, so ids, prices and
codes copy as they are. On Persian pages these tiny fonts draw 0-9 as
the Persian digits from Vazirmatn. Run from the repository root:

    python3 -m pip install fonttools brotli
    python3 scripts/admin_digit_font.py
"""
from fontTools import subset
from fontTools.ttLib import TTFont

STATIC = "backend/internal/admin/static/"

for weight in ("Regular", "Bold"):
    font = TTFont(STATIC + f"Vazirmatn-{weight}.ttf")
    best = font.getBestCmap()
    persian = {0x30 + i: best[0x6F0 + i] for i in range(10)}
    opts = subset.Options()
    opts.flavor = "woff2"
    opts.layout_features = []
    opts.name_IDs = ["*"]
    sub = subset.Subsetter(opts)
    sub.populate(glyphs=list(persian.values()))
    sub.subset(font)
    for table in font["cmap"].tables:
        if table.isUnicode():
            table.cmap = dict(persian)
    font.flavor = "woff2"
    font.save(STATIC + f"VazirmatnDigits-{weight}.woff2")
