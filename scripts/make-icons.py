#!/usr/bin/env python
"""Regenerate Threadly branding assets from a drawn master image.

Usage: python scripts/make-icons.py

Draws the 1024x1024 master (family terracotta palette, thread-tree mark)
into assets/branding/icon-source.png, then emits the platform artifacts
Rivet consumes: assets/branding/app.ico (Windows) and
assets/branding/app.icns (macOS bundle).

To restyle the icon, edit draw_master() and rerun; do not hand-edit the
generated .ico/.icns. Same pipeline as PodLens (scripts/make-icons.py).
"""

from __future__ import annotations

import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

BRANDING = Path(__file__).resolve().parent.parent / "assets" / "branding"

ACCENT = (193, 95, 60)        # family accent #c15f3c
ACCENT_DEEP = (168, 78, 47)   # gradient floor
WHITE = (255, 255, 255)

MASTER = 1024
SS = 4  # supersample factor for smooth curves


def draw_master() -> Image.Image:
    size = MASTER * SS
    # Vertical gradient backdrop, rounded like a modern app tile.
    gradient = Image.linear_gradient("L").resize((size, size))
    backdrop = ImageOps.colorize(gradient, black=ACCENT_DEEP, white=ACCENT)

    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=892, fill=255
    )
    image.paste(backdrop, (0, 0), mask)
    draw = ImageDraw.Draw(image)

    # Thread mark: three staggered capsules stepping right-then-right —
    # root post, nested reply, deeper reply — the staircase shape of an
    # indented discussion. Coordinates in 1024-space; capsules carry their
    # own round caps (rounded_rectangle radius = half stroke).
    def capsule(x0, y0, x1, y1):
        draw.rounded_rectangle(
            (x0 * SS, y0 * SS, x1 * SS, y1 * SS), radius=44 * SS, fill=WHITE
        )

    capsule(280, 308, 744, 396)   # root post
    capsule(392, 468, 652, 556)   # nested reply (indented)
    capsule(504, 628, 588, 716)   # deeper reply (a dot, further indented)

    return image.resize((MASTER, MASTER), Image.LANCZOS)


def write_icns(master: Image.Image, path: Path) -> None:
    entries = (
        (b"ic07", 128),
        (b"ic08", 256),
        (b"ic09", 512),
        (b"ic10", 1024),
    )
    payload = b""
    for icon_type, edge in entries:
        buffer = path.with_name(f".icns-tmp-{edge}.png")
        master.resize((edge, edge), Image.LANCZOS).save(buffer, format="PNG")
        data = buffer.read_bytes()
        buffer.unlink()
        payload += icon_type + struct.pack(">I", len(data) + 8) + data
    icns = b"icns" + struct.pack(">I", len(payload) + 8) + payload
    path.write_bytes(icns)


def main() -> None:
    BRANDING.mkdir(parents=True, exist_ok=True)
    master = draw_master()
    master.save(BRANDING / "icon-source.png")

    master.save(
        BRANDING / "app.ico",
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
               (64, 64), (128, 128), (256, 256)],
    )

    write_icns(master, BRANDING / "app.icns")
    for name in ("icon-source.png", "app.ico", "app.icns"):
        print(f"{(BRANDING / name).name}: {(BRANDING / name).stat().st_size} bytes")


if __name__ == "__main__":
    main()
