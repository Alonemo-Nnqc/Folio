"""Browser extension icons from the app icon, so the toolbar button matches Folio.

Usage: python3 -I script/extension-icons.py <app-icon-1024.png> BrowserExtension/shared
The 1024 render comes from the Icon Composer document:
  ictool Folio/Resources/Folio.icon --export-image --output-file app-1024.png \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
"""
import sys, os
from PIL import Image, ImageFilter

src, out = sys.argv[1], sys.argv[2]
icon = Image.open(src).convert('RGBA')

# Toolbar sizes fill the square; the larger ones (extensions page, store listing) keep the
# macOS icon's margin, as the app icon does in Finder and the Dock.
SCALE = {16: 0.94, 19: 0.94, 32: 0.94, 38: 0.94, 48: 0.82, 96: 0.82, 128: 0.82}
for size, scale in SCALE.items():
    side = round(size * scale)
    art = icon.resize((side * 4, side * 4), Image.LANCZOS).resize((side, side), Image.LANCZOS)
    if size <= 19:
        art = art.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=0))
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.paste(art, ((size - side) // 2, (size - side) // 2), art)
    canvas.save(os.path.join(out, f'icon-{size}.png'), optimize=True)
    print(size, side)
