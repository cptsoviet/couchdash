"""CouchDash: turns the rendered masters in branding/out/ (render.js) into Android resources.

  icon.png   512x512   -> mipmap-*/ic_launcher.png (48..192 px)
  banner.png 1280x720  -> drawable-xhdpi/banner.png (640x360 = 320x180 dp) and drawable-xxxhdpi/banner.png (4K)
  splash.png 1600x900  -> drawable-xxxhdpi/splash_logo.png, centred on a gradient by res/drawable/launch_background.xml
                          (400x225 dp on any screen; Android scales it down from 4x, so it stays sharp at 4K)
Run from the repo root: python3 branding/make_assets.py
"""
from pathlib import Path

from PIL import Image

out = Path(__file__).parent / "out"
res = Path(__file__).parent.parent / "android/app/src/main/res"


def save(img, path, size=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    (img.resize(size, Image.LANCZOS) if size else img).save(path, optimize=True)
    print(path.relative_to(res.parent.parent.parent.parent.parent), img.size if size is None else size)


icon = Image.open(out / "icon.png")
for folder, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    save(icon, res / f"mipmap-{folder}/ic_launcher.png", (px, px))

banner = Image.open(out / "banner.png").convert("RGB")
save(banner, res / "drawable-xhdpi/banner.png", (640, 360))
save(banner, res / "drawable-xxxhdpi/banner.png")

save(Image.open(out / "splash.png"), res / "drawable-xxxhdpi/splash_logo.png")
