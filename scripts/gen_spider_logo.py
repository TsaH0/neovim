#!/usr/bin/env python3
# Generates the Spider logo: runtime/spider.svg (vector), plus PNG and ICO
# renders of the same geometry. Requires Pillow.
#
# Usage: python3 scripts/gen_spider_logo.py OUTDIR
#   then copy OUTDIR/spider.svg, OUTDIR/spider-128.png (as spider.png) and
#   OUTDIR/spider.ico to runtime/.
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]

BG1, BG2 = '#8B6CF0', '#5A3FD6'   # purple disc (gradient)
INK = '#16131F'                    # spider
EYE = '#7CF29C'                    # green eyes
RIM = '#C9BDFF'

legs_left = [
    [(232, 196), (150, 142), (118, 66)],
    [(228, 210), (118, 192), (66, 148)],
    [(228, 226), (118, 254), (72, 316)],
    [(234, 242), (150, 314), (122, 402)],
]
def mirror(pts):
    return [(512 - x, y) for x, y in pts]
legs = legs_left + [mirror(l) for l in legs_left]

# --- SVG ---
def poly(pts):
    return ' '.join(f'{x},{y}' for x, y in pts)
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <title>Spider</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{BG1}"/>
      <stop offset="1" stop-color="{BG2}"/>
    </linearGradient>
  </defs>
  <circle cx="256" cy="256" r="244" fill="url(#bg)"/>
  <circle cx="256" cy="256" r="236" fill="none" stroke="{RIM}" stroke-opacity="0.35" stroke-width="4"/>
  <line x1="256" y1="14" x2="256" y2="160" stroke="{INK}" stroke-width="7" stroke-linecap="round"/>
  <g fill="none" stroke="{INK}" stroke-width="20" stroke-linecap="round" stroke-linejoin="round">
''' + ''.join(f'    <polyline points="{poly(l)}"/>\n' for l in legs) + f'''  </g>
  <g fill="{INK}">
    <ellipse cx="256" cy="318" rx="74" ry="90"/>
    <circle cx="256" cy="206" r="52"/>
  </g>
  <path d="M256 268 L276 300 L256 352 L236 300 Z" fill="{BG1}" opacity="0.55"/>
  <g fill="{EYE}">
    <circle cx="236" cy="196" r="11"/>
    <circle cx="276" cy="196" r="11"/>
  </g>
</svg>
'''
open(f'{out}/spider.svg', 'w').write(svg)

# --- Raster (supersampled) ---
S = 2048
k = S / 512
img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
# Gradient disc.
grad = Image.new('RGBA', (S, S))
gd = ImageDraw.Draw(grad)
def hexrgb(h):
    h = h.lstrip('#'); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
c1, c2 = hexrgb(BG1), hexrgb(BG2)
for i in range(2 * S):
    t = i / (2 * S)
    col = tuple(int(c1[j] + (c2[j] - c1[j]) * t) for j in range(3)) + (255,)
    gd.line([(i, 0), (0, i)], fill=col, width=2)
mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).ellipse([(256-244)*k, (256-244)*k, (256+244)*k, (256+244)*k], fill=255)
img.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(img)
rim = hexrgb(RIM) + (90,)
d.ellipse([(256-236)*k, (256-236)*k, (256+236)*k, (256+236)*k], outline=rim, width=int(4*k))
ink = hexrgb(INK) + (255,)
def thick_line(pts, w):
    pts = [(x*k, y*k) for x, y in pts]
    d.line(pts, fill=ink, width=int(w*k), joint='curve')
    r = w*k/2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x-r, y-r, x+r, y+r], fill=ink)
thick_line([(256, 14), (256, 160)], 7)
for l in legs:
    thick_line(l, 20)
d.ellipse([(256-74)*k, (318-90)*k, (256+74)*k, (318+90)*k], fill=ink)
d.ellipse([(256-52)*k, (206-52)*k, (256+52)*k, (206+52)*k], fill=ink)
d.polygon([(256*k, 268*k), (276*k, 300*k), (256*k, 352*k), (236*k, 300*k)], fill=hexrgb(BG1) + (140,))
eye = hexrgb(EYE) + (255,)
for cx in (236, 276):
    d.ellipse([(cx-11)*k, (196-11)*k, (cx+11)*k, (196+11)*k], fill=eye)

for size in (512, 256, 128):
    img.resize((size, size), Image.LANCZOS).save(f'{out}/spider-{size}.png')
img.resize((256, 256), Image.LANCZOS).save(f'{out}/spider.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
