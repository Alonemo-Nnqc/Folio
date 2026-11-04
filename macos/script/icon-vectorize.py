"""Turn the flat icon illustration into per-layer SVGs on Icon Composer's 1024 canvas.

Usage: python3 -I script/icon-vectorize.py doc/assets/app-icon-source.webp <out-dir>
The SVGs go into Folio/Resources/Folio.icon/Assets; icon.json there sets layer order and glass.
"""
import sys, os
import numpy as np
from PIL import Image
from scipy import ndimage
import contourpy

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
im = np.asarray(Image.open(src).convert('RGB')).astype(float)
H, W, _ = im.shape

# Image squircle centre and the scale onto the 1024 canvas (keeps the artwork's proportions,
# leaves room for Liquid Glass shadows inside the macOS shape).
CX, CY, K = 626.0, 627.5, 1.05

palette = {
    'bg':        (245, 242, 234),
    'page':      (250, 248, 242),
    'light':     (204, 204, 204),
    'warm':      (184, 180, 175),
    'navy':      (51, 56, 68),
    'orange':    (244, 118, 70),
}
names = list(palette)
cols = np.array([palette[n] for n in names])
d = ((im[:, :, None, :] - cols[None, None]) ** 2).sum(-1)
label = d.argmin(-1)

yy, xx = np.mgrid[0:H, 0:W]
inside = (xx > 330) & (xx < 925) & (yy > 280) & (yy < 975)
masks = {n: (label == i) & inside for i, n in enumerate(names)}

# The text lines share the warm card's grey; split them out by where they sit on the page.
lines_box = (xx > 570) & (xx < 830) & (yy > 515) & (yy < 705)
masks['lines'] = masks['warm'] & lines_box
masks['warm'] = masks['warm'] & ~lines_box

# Anti-aliased edge pixels land in whichever class is nearest; clean specks.
for n in list(masks):
    if n == 'bg':
        continue
    m = ndimage.binary_opening(masks[n], iterations=1)
    lab, k = ndimage.label(m)
    if k:
        sizes = ndimage.sum(m, lab, range(1, k + 1))
        m = np.isin(lab, [i + 1 for i, s in enumerate(sizes) if s > 150])
    masks[n] = ndimage.binary_closing(m, iterations=2)

# The page and the background cream differ by only a few levels, so the page comes from a
# blurred brightness map: its largest bright component, holes (text lines, bookmark) filled.
bright = (ndimage.gaussian_filter(im.sum(-1), 1.5) > 732) & inside
bright = ndimage.binary_opening(bright, iterations=5)
lab, k = ndimage.label(bright)
sizes = ndimage.sum(bright, lab, range(1, k + 1))
masks['page'] = ndimage.binary_fill_holes(ndimage.binary_closing(lab == (sizes.argmax() + 1), iterations=3))

# The tray's rim and the lip under the page are a soft gradient in the source, so they are drawn
# as one clean polygon; its lower edges sit under the navy tray, its upper-left edge is the line
# where the cards drop into the tray.
from PIL import ImageDraw
rim = Image.new('L', (W, H), 0)
ImageDraw.Draw(rim).polygon([(352, 511), (379, 496), (526, 639), (650, 639), (650, 700), (900, 700), (905, 738),
                             (912, 770), (912, 790), (700, 850), (352, 560)], fill=255)
masks['page'] = masks['page'] | (np.asarray(rim) > 0)

core = {n: ndimage.binary_erosion(masks[n], iterations=3) for n in masks}
fills = {n: '#%02X%02X%02X' % tuple(int(round(v)) for v in im[core[n]].mean(0)) for n in masks if n != 'bg'}
fills['page'] = '#FBF8F2'
print(fills)

# Painter's order, back to front. Each back layer reaches a few pixels under the layers in front
# of it, so no hairline of background shows through at shared edges.
order = ['light', 'warm', 'page', 'lines', 'navy', 'orange']
for i, n in enumerate(order):
    front = np.zeros_like(masks[n])
    for f in order[i + 1:]:
        front |= masks[f]
    grown = ndimage.binary_dilation(masks[n], iterations=4)
    masks[n] = masks[n] | (grown & front)

def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    a, b = pts[0], pts[-1]
    ab = b - a
    n = np.hypot(*ab)
    if n == 0:
        dist = np.hypot(*(pts - a).T)
    else:
        dist = np.abs(ab[0] * (pts[:, 1] - a[1]) - ab[1] * (pts[:, 0] - a[0])) / n
    i = dist.argmax()
    if dist[i] > eps:
        return np.vstack([rdp(pts[:i + 1], eps)[:-1], rdp(pts[i:], eps)])
    return np.array([a, b])

UP = 4
def to_path(mask):
    m = np.asarray(Image.fromarray((mask * 255).astype(np.uint8)).resize((W * UP, H * UP), Image.BILINEAR)).astype(float) / 255
    m = ndimage.gaussian_filter(m, sigma=UP * 1.2)
    gen = contourpy.contour_generator(z=m, line_type='Separate')
    parts = []
    for line in gen.lines(0.5):
        if len(line) < 8:
            continue
        p = line[:, ::-1][:, ::-1]  # contourpy returns (x, y)
        p = p / UP
        p = np.column_stack([CX * 0 + 512 + (p[:, 0] - CX) * K, 512 + (p[:, 1] - CY) * K])
        p = rdp(p, 0.25)
        parts.append('M' + ' L'.join(f'{x:.2f} {y:.2f}' for x, y in p) + ' Z')
    return ' '.join(parts)

for n in order:
    path = to_path(masks[n])
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
           f'  <path fill="{fills[n]}" fill-rule="evenodd" d="{path}"/>\n</svg>\n')
    open(os.path.join(out, f'{n}.svg'), 'w').write(svg)
    print(n, int(masks[n].sum()), len(path))
