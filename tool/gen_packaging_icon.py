#!/usr/bin/env python3
"""Regenerate the Linux packaging icon from the master logo.

Linux has no in-toolchain launcher-icon mechanism, so unlike every other
platform its icon is not produced by `flutter_launcher_icons` — it is committed
beside the .desktop file and picked up at packaging time by
tool/appimage/build-appimage.sh and build-flutterpi-appimage.sh.

512x512 is deliberate: the master brainframe.png is 1024x1024, which exceeds
the largest hicolor size linuxdeploy accepts.

    python3 tool/gen_packaging_icon.py

Requires Pillow. Rerun it whenever brainframe.png changes.
"""

import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install --user Pillow")

SIZE = 512
ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "brainframe.png"
TARGET = ROOT / "linux" / "packaging" / f"brainframe-{SIZE}.png"


def main() -> None:
    if not SOURCE.exists():
        sys.exit(f"master logo not found: {SOURCE}")
    with Image.open(SOURCE) as src:
        icon = src.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
        icon.save(TARGET, optimize=True)
    print(f"{TARGET.relative_to(ROOT)} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
