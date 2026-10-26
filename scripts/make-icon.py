#!/usr/bin/env python3
"""Draws MarDock's app icon and writes App/AppIcon.icns (+ docs/icon.png).

The icon: a deep-sea gradient squircle ("mar" is the sea) holding a frosted
glass dock whose tiles swell like a wave — the magnification curve.

Requires Pillow. Run from the repository root: python3 scripts/make-icon.py
"""
import io
import math
import struct
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048  # supersampled canvas; downsampled at the end for clean edges


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(int(round(lerp(a, b, t))) for a, b in zip(c1, c2))


def gradient(size, stops, angle_deg):
    """Linear gradient across `size` at `angle_deg` through colour `stops`."""
    w, h = size
    img = Image.new("RGBA", size)
    px = img.load()
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    span = abs(w * dx) + abs(h * dy)
    for y in range(h):
        for x in range(w):
            t = ((x - w / 2) * dx + (y - h / 2) * dy) / span + 0.5
            t = min(max(t, 0), 1)
            for i in range(len(stops) - 1):
                p0, c0 = stops[i]
                p1, c1 = stops[i + 1]
                if t <= p1:
                    px[x, y] = mix(c0, c1, (t - p0) / max(p1 - p0, 1e-6)) + (255,)
                    break
    return img


def superellipse_mask(size, box, n=5.0):
    mask = Image.new("L", size, 0)
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    a, b = (x1 - x0) / 2, (y1 - y0) / 2
    points = []
    for i in range(720):
        t = 2 * math.pi * i / 720
        c, s = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(c) ** (2 / n), c)
        y = cy + b * math.copysign(abs(s) ** (2 / n), s)
        points.append((x, y))
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def radial_glow(size, center, radius, color, strength):
    glow = Image.new("RGBA", size, color + (0,))
    alpha = Image.new("L", size, 0)
    d = ImageDraw.Draw(alpha)
    steps = 60
    for i in range(steps, 0, -1):
        r = radius * i / steps
        v = int(255 * strength * (1 - i / steps) ** 1.6)
        d.ellipse((center[0] - r, center[1] - r, center[0] + r, center[1] + r), fill=v)
    glow.putalpha(alpha.filter(ImageFilter.GaussianBlur(radius / 12)))
    return glow


def draw_icon():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Body: Apple's macOS grid puts an 824/1024 squircle in the middle.
    inset = S * 100 / 1024
    body_box = (inset, inset, S - inset, S - inset)
    body_mask = superellipse_mask((S, S), body_box, n=5.2)

    # Drop shadow under the body.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow_alpha = body_mask.point(lambda v: int(v * 0.45))
    shadow.putalpha(shadow_alpha)
    shadow = shadow.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -S * 0.018))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.02))
    canvas = Image.alpha_composite(canvas, shadow)

    # Deep sea: indigo night → ocean blue → aqua.
    small = 256
    sea = gradient((small, small), [(0, (22, 16, 74)), (0.45, (32, 70, 190)), (0.8, (18, 160, 200)), (1, (40, 220, 205))], 62)
    sea = sea.resize((S, S), Image.BICUBIC)

    # Aurora glows.
    sea = Image.alpha_composite(sea, radial_glow((S, S), (S * 0.24, S * 0.22), S * 0.55, (150, 90, 255), 0.75))
    sea = Image.alpha_composite(sea, radial_glow((S, S), (S * 0.86, S * 0.4), S * 0.45, (255, 110, 190), 0.38))

    # Gentle waves in the lower half.
    waves = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    wd = ImageDraw.Draw(waves)
    for k, (base, amp, alpha) in enumerate([(0.58, 0.022, 34), (0.66, 0.028, 26), (0.74, 0.03, 20)]):
        pts = []
        for i in range(0, 401):
            x = S * i / 400
            y = S * base + S * amp * math.sin(2 * math.pi * (i / 400) * 1.6 + k * 1.3)
            pts.append((x, y))
        pts += [(S, S), (0, S)]
        wd.polygon(pts, fill=(255, 255, 255, alpha))
    sea = Image.alpha_composite(sea, waves.filter(ImageFilter.GaussianBlur(S * 0.004)))

    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    body.paste(sea, (0, 0), body_mask)
    canvas = Image.alpha_composite(canvas, body)

    # The glass dock.
    dock_box = (S * 0.13, S * 0.615, S * 0.87, S * 0.745)
    dock_radius = S * 0.05
    dock_mask = rounded_mask((S, S), dock_box, dock_radius)
    # soft shadow beneath the glass
    ds = Image.new("RGBA", (S, S), (6, 10, 40, 0))
    ds.putalpha(dock_mask.point(lambda v: int(v * 0.35)))
    ds = ds.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -S * 0.012)).filter(ImageFilter.GaussianBlur(S * 0.018))
    canvas = Image.alpha_composite(canvas, ds)
    glass = gradient((64, 64), [(0, (255, 255, 255)), (1, (220, 240, 255))], 90).resize((S, S))
    glass_alpha = dock_mask.point(lambda v: int(v * 0.34))
    glass.putalpha(glass_alpha)
    canvas = Image.alpha_composite(canvas, glass)
    # glass edge highlight (brighter on top)
    edge = Image.new("L", (S, S), 0)
    ImageDraw.Draw(edge).rounded_rectangle(dock_box, radius=dock_radius, outline=255, width=int(S * 0.006))
    fade = gradient((8, 64), [(0, (255, 255, 255)), (1, (90, 90, 90))], 90).convert("L").resize((S, S))
    fade = fade.crop((0, 0, S, S))
    edge = ImageChops.multiply(edge, fade)
    edge_layer = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    edge_layer.putalpha(edge.point(lambda v: int(v * 0.85)))
    canvas = Image.alpha_composite(canvas, edge_layer)

    # Tiles swelling like a wave (the magnification curve).
    palette = [
        ((255, 120, 110), (255, 70, 120)),   # coral
        ((255, 205, 90), (255, 140, 40)),    # amber
        ((255, 255, 255), (170, 230, 255)),  # glass-white hero tile
        ((110, 240, 190), (20, 180, 150)),   # mint
        ((180, 150, 255), (110, 80, 240)),   # violet
    ]
    sizes = [0.093, 0.124, 0.178, 0.124, 0.093]
    gap = S * 0.021
    total = sum(s * S for s in sizes) + gap * (len(sizes) - 1)
    x = S / 2 - total / 2
    baseline = dock_box[3] - S * 0.028
    for i, (size, (c0, c1)) in enumerate(zip(sizes, palette)):
        w = size * S
        box = (x, baseline - w, x + w, baseline)
        tile_mask = superellipse_mask((S, S), box, n=4.6)
        # shadow
        ts = Image.new("RGBA", (S, S), (10, 15, 50, 0))
        ts.putalpha(tile_mask.point(lambda v: int(v * 0.4)))
        ts = ts.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -S * 0.01)).filter(ImageFilter.GaussianBlur(S * 0.012))
        canvas = Image.alpha_composite(canvas, ts)
        tile = gradient((64, 64), [(0, c0), (1, c1)], 90).resize((S, S))
        tile.putalpha(tile_mask)
        canvas = Image.alpha_composite(canvas, tile)
        # gloss on the upper half of each tile
        gloss_mask = ImageChops.multiply(tile_mask, Image.new("L", (S, S), 0))
        gm = Image.new("L", (S, S), 0)
        ImageDraw.Draw(gm).ellipse((box[0] - w * 0.3, box[1] - w * 0.75, box[2] + w * 0.3, box[1] + w * 0.48), fill=255)
        gloss_mask = ImageChops.multiply(tile_mask, gm).point(lambda v: int(v * 0.22))
        gloss = Image.new("RGBA", (S, S), (255, 255, 255, 0))
        gloss.putalpha(gloss_mask)
        canvas = Image.alpha_composite(canvas, gloss)
        if i == 2:
            # A wave glyph on the hero tile and its running indicator.
            glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            gd = ImageDraw.Draw(glyph)
            pts = []
            for j in range(0, 201):
                t = j / 200
                px = box[0] + w * (0.2 + 0.6 * t)
                py = box[1] + w * (0.47 + 0.09 * math.sin(2 * math.pi * t * 1.0 + 0.3))
                pts.append((px, py))
            gd.line(pts, fill=(40, 110, 220, 255), width=int(w * 0.09), joint="curve")
            pts2 = [(p[0], p[1] + w * 0.2) for p in pts]
            gd.line(pts2, fill=(60, 190, 230, 230), width=int(w * 0.07), joint="curve")
            glyph.putalpha(ImageChops.multiply(glyph.getchannel("A"), tile_mask))
            canvas = Image.alpha_composite(canvas, glyph)
            dot_r = S * 0.0085
            cx = (box[0] + box[2]) / 2
            cy = dock_box[3] - S * 0.013
            glow = radial_glow((S, S), (cx, cy), S * 0.03, (160, 240, 255), 0.9)
            canvas = Image.alpha_composite(canvas, glow)
            dot = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            ImageDraw.Draw(dot).ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r), fill=(235, 252, 255, 255))
            canvas = Image.alpha_composite(canvas, dot)
        x += w + gap

    # Specular sheen across the top of the body + a crisp inner edge.
    sheen = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sheen).ellipse((-S * 0.25, -S * 0.75, S * 1.25, S * 0.42), fill=255)
    sheen = ImageChops.multiply(sheen.filter(ImageFilter.GaussianBlur(S * 0.03)), body_mask).point(lambda v: int(v * 0.10))
    sheen_layer = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    sheen_layer.putalpha(sheen)
    canvas = Image.alpha_composite(canvas, sheen_layer)

    rim = ImageChops.subtract(body_mask, superellipse_mask((S, S), (inset + 5, inset + 5, S - inset - 5, S - inset - 5), n=5.2))
    rim_layer = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    rim_layer.putalpha(rim.point(lambda v: int(v * 0.28)))
    canvas = Image.alpha_composite(canvas, rim_layer)

    return canvas.resize((1024, 1024), Image.LANCZOS)


def png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_icns(master, path):
    # (type, pixel size) — PNG payloads are supported for all of these.
    entries = [
        (b"icp4", 16), (b"icp5", 32), (b"ic11", 32), (b"icp6", 64), (b"ic12", 64),
        (b"ic07", 128), (b"ic13", 256), (b"ic08", 256), (b"ic14", 512), (b"ic09", 512), (b"ic10", 1024),
    ]
    chunks = b""
    for kind, px in entries:
        data = png_bytes(master.resize((px, px), Image.LANCZOS))
        chunks += kind + struct.pack(">I", len(data) + 8) + data
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


if __name__ == "__main__":
    icon = draw_icon()
    icon.save("docs/icon.png", optimize=True)
    write_icns(icon, "App/AppIcon.icns")
    print("wrote App/AppIcon.icns and docs/icon.png", file=sys.stderr)
