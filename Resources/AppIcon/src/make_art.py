#!/usr/bin/env python3
"""Generate artwork.svg for the PicLight app icon.

Emits a transparent 1024x1024 SVG drawn for the Icon Composer canvas. Everything here is
foreground art: the rounded-square glass tile comes from the .icon document's `fill`.

The renderer is Apple's CoreSVG (Icon Composer / ictool, and ImageIO for sips), so this file
deliberately sticks to gradients, paths, opacity, clipPath and feGaussianBlur.
`mix-blend-mode` is NOT supported there and must not be used.

Geometry is built in a rotated local frame whose +y axis runs from the flashlight lens (y=0)
towards the tail, so the barrel is a vertical cylinder and the fingers are simple horizontals.

Occlusion order — this is what makes a fist read as a fist:
    beam -> flashlight -> fingers -> back of hand (hides the finger bases) -> thumb -> cuff
"""
import math

# --------------------------------------------------------------------------- frame
LENS = (700.0, 300.0)      # lens centre on the 1024 canvas
ANGLE = 42.0               # degrees clockwise; the local +x axis tilts to the lower-right
BARREL_R = 70.0            # barrel radius in the local frame
HEAD_R = 118.0             # head cone radius at the bezel
OUTLINE = "#22384F"
BEAM_W = 25.0              # beam half-angle, degrees
SW = 15.0                  # master outline width at 1024


def rot(x, y, deg=ANGLE):
    """Local -> canvas: rotate `deg` degrees clockwise about the lens, then translate."""
    a = math.radians(deg)
    s, c = math.sin(a), math.cos(a)
    return (LENS[0] + x * c - y * s, LENS[1] + x * s + y * c)


def frame(name, extra=""):
    return (f'  <g id="{name}" transform="translate({LENS[0]:.0f},{LENS[1]:.0f}) '
            f'rotate({ANGLE:.0f})" stroke="{OUTLINE}" stroke-width="{SW:.0f}" '
            f'stroke-linejoin="round" stroke-linecap="round"{extra}>')


# --------------------------------------------------------------------------- beam
def beam():
    """Wedge from the lens rim to the top-right corner, plus a soft bloom at the lens."""
    a = math.radians(ANGLE)
    ax = (math.sin(a), -math.cos(a))          # axis direction (local -y) in canvas space
    px = (math.cos(a), math.sin(a))           # in-plane perpendicular
    ra = (LENS[0] + HEAD_R * px[0], LENS[1] + HEAD_R * px[1])
    rb = (LENS[0] - HEAD_R * px[0], LENS[1] - HEAD_R * px[1])
    base = math.degrees(math.atan2(ax[1], ax[0]))
    far = 1250.0
    ends = []
    for rim, sign in ((ra, 1), (rb, -1)):
        d = math.radians(base + sign * BEAM_W)
        ends.append((rim[0] + far * math.cos(d), rim[1] + far * math.sin(d)))
    poly = [rb, ends[1], ends[0], ra]
    gx2, gy2 = LENS[0] + ax[0] * 900, LENS[1] + ax[1] * 900
    pts = " ".join("%.1f,%.1f" % p for p in poly)
    return f'''  <g id="beam">
    <defs>
      <linearGradient id="beamGrad" gradientUnits="userSpaceOnUse" x1="{LENS[0]}" y1="{LENS[1]}" x2="{gx2:.0f}" y2="{gy2:.0f}">
        <stop offset="0.00" stop-color="#FFF7D2" stop-opacity="1.00"/>
        <stop offset="0.16" stop-color="#FFE07C" stop-opacity="0.97"/>
        <stop offset="0.52" stop-color="#FFD75F" stop-opacity="0.80"/>
        <stop offset="1.00" stop-color="#FFE9A8" stop-opacity="0.20"/>
      </linearGradient>
      <radialGradient id="lensGlow" gradientUnits="userSpaceOnUse" cx="{LENS[0]}" cy="{LENS[1]}" r="200">
        <stop offset="0.00" stop-color="#FFFDF2" stop-opacity="0.90"/>
        <stop offset="0.50" stop-color="#FFEDA6" stop-opacity="0.36"/>
        <stop offset="1.00" stop-color="#FFEDA6" stop-opacity="0.00"/>
      </radialGradient>
    </defs>
    <polygon points="{pts}" fill="url(#beamGrad)"/>
    <circle cx="{LENS[0]}" cy="{LENS[1]}" r="200" fill="url(#lensGlow)"/>
  </g>'''


# --------------------------------------------------------------------------- flashlight
def flashlight():
    r, hr = BARREL_R, HEAD_R
    return f'''{frame("flashlight")}
    <!-- tail cap -->
    <path d="M {-r} 452 L {r} 452 L {r} 500 Q {r} 566 0 566 Q {-r} 566 {-r} 500 Z" fill="url(#bodyGrad)"/>
    <!-- barrel -->
    <rect x="{-r}" y="176" width="{2 * r}" height="290" fill="url(#bodyGrad)"/>
    <!-- barrel top-left shading so the cylinder reads as round -->
    <rect x="{-r + 6}" y="180" width="26" height="282" rx="13" fill="#93AAC6" opacity="0.22" stroke="none"/>
    <!-- collar -->
    <path d="M {-r - 10} 178 L {r + 10} 178 L {r - 2} 146 L {-r + 2} 146 Z" fill="url(#headGrad)"/>
    <!-- head cone -->
    <path d="M {-hr} 8 A {hr} 46 0 0 0 {hr} 8 L {r - 2} 150 L {-r + 2} 150 Z" fill="url(#headGrad)"/>
    <!-- bezel -->
    <ellipse cx="0" cy="8" rx="{hr}" ry="46" fill="url(#headGrad)"/>
    <!-- lens -->
    <ellipse cx="0" cy="6" rx="96" ry="36" fill="url(#lensGrad)"/>
    <ellipse cx="0" cy="6" rx="96" ry="36" fill="none" stroke="{OUTLINE}" stroke-width="7" opacity="0.45"/>
    <!-- specular glint on the lens -->
    <ellipse cx="-34" cy="-6" rx="26" ry="11" fill="#FFFDF0" opacity="0.75" stroke="none"/>
    <!-- switch -->
    <rect x="-24" y="188" width="48" height="104" rx="24" fill="url(#btnGrad)"/>
  </g>'''


# --------------------------------------------------------------------------- glove
# (top y, tip x) — index first, pinky last; each finger is a full outlined capsule so the
# stack reads as separate fingers, and they overlap by OVERLAP so upper fingers sit in front.
FINGERS = [
    (266.0, 78.0),
    (324.0, 90.0),
    (386.0, 80.0),
    (448.0, 62.0),
]
FINGER_H = 66.0
FINGER_LEFT = -96.0


def fingers():
    out = []
    for top, tip in reversed(FINGERS):          # pinky first, index painted last (in front)
        bot = top + FINGER_H
        r = FINGER_H / 2
        out.append(f'    <rect x="{FINGER_LEFT}" y="{top:.0f}" width="{tip - FINGER_LEFT:.0f}" '
                   f'height="{FINGER_H:.0f}" rx="{r:.0f}" fill="url(#gloveGrad)"/>')
    return "\n".join(out)


def hand():
    """Back of the hand: drawn after the fingers so it hides their bases and the barrel's left."""
    return f'''    <path d="M -30 240
             Q -152 250 -184 350
             Q -214 472 -130 548
             Q -86 594 -20 584
             Q -12 430 -30 240
             Z" fill="url(#gloveGrad)"/>'''


def thumb():
    return f'''    <path d="M -178 372 Q -196 268 -108 240 Q -30 214 4 250
             Q -22 300 -78 338 Q -128 372 -178 372 Z" fill="url(#gloveGrad2)"/>'''


def cuff():
    return f'''    <path d="M -250 566 L 66 566 L 66 676 Q 66 730 14 730 L -196 730 Q -250 730 -250 676 Z" fill="url(#gloveGrad2)"/>
    <path d="M -216 618 L 40 618" stroke="{OUTLINE}" stroke-width="10" opacity="0.30" fill="none"/>'''


def glove():
    return f'''{frame("glove")}
{fingers()}
{hand()}
{thumb()}
{cuff()}
  </g>'''


DEFS = '''  <defs>
    <linearGradient id="bodyGrad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0.00" stop-color="#BCCCE1"/>
      <stop offset="0.22" stop-color="#F7FAFF"/>
      <stop offset="0.52" stop-color="#FFFFFF"/>
      <stop offset="0.84" stop-color="#EAF1F9"/>
      <stop offset="1.00" stop-color="#B0C4DB"/>
    </linearGradient>
    <linearGradient id="headGrad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0.00" stop-color="#B4C7DE"/>
      <stop offset="0.24" stop-color="#F9FCFF"/>
      <stop offset="0.56" stop-color="#FFFFFF"/>
      <stop offset="0.86" stop-color="#E4EDF7"/>
      <stop offset="1.00" stop-color="#A8BDD7"/>
    </linearGradient>
    <radialGradient id="lensGrad" cx="0.36" cy="0.24" r="0.88">
      <stop offset="0.00" stop-color="#FFFEF6"/>
      <stop offset="0.38" stop-color="#FFE88F"/>
      <stop offset="0.78" stop-color="#FFC61F"/>
      <stop offset="1.00" stop-color="#E9A000"/>
    </radialGradient>
    <linearGradient id="btnGrad" x1="0" y1="0" x2="1" y2="0.3">
      <stop offset="0.00" stop-color="#F2A015"/>
      <stop offset="0.42" stop-color="#FFD463"/>
      <stop offset="1.00" stop-color="#E48805"/>
    </linearGradient>
    <linearGradient id="gloveGrad" x1="0.10" y1="0" x2="0.90" y2="1">
      <stop offset="0.00" stop-color="#FFFFFF"/>
      <stop offset="0.58" stop-color="#FCFDFF"/>
      <stop offset="1.00" stop-color="#D4E1F0"/>
    </linearGradient>
    <linearGradient id="gloveGrad2" x1="0.16" y1="0" x2="0.94" y2="1">
      <stop offset="0.00" stop-color="#FFFFFF"/>
      <stop offset="0.66" stop-color="#F2F7FD"/>
      <stop offset="1.00" stop-color="#C9D9EC"/>
    </linearGradient>
  </defs>'''

HEADER = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <!-- GENERATED by make_art.py - do not edit by hand. -->
'''

def write_layers(outdir):
    """Emit the two SVG layers the .icon package ships: the beam and the subject."""
    import os
    os.makedirs(outdir, exist_ok=True)
    body = "\n".join([HEADER, DEFS, "", flashlight(), "", glove(), "</svg>", ""])
    # beam.svg must carry its own <defs>, since a .icon layer is rasterised on its own
    bsvg = beam()
    inner_defs = bsvg.split("<defs>", 1)[1].split("</defs>", 1)[0]
    bsvg = bsvg.replace(inner_defs, "").replace("<defs></defs>", "")
    bsvg = bsvg.replace('  <g id="beam">', '  <g id="beam">', 1)
    beam_file = "\n".join([HEADER, "  <defs>" + inner_defs + "</defs>", "", bsvg.strip(), "</svg>", ""])
    # the beam's bloom lives outside <defs>; keep it simple by re-emitting the whole group
    for name, text in (("artwork.svg", body), ("beam.svg", beam_file)):
        path = os.path.join(outdir, name)
        with open(path, "w") as f:
            f.write(text)
        print("wrote %s (%d bytes)" % (path, len(text)))


if __name__ == "__main__":
    import sys
    write_layers(sys.argv[1] if len(sys.argv) > 1 else ".")
