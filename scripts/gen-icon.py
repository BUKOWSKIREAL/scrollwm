#!/usr/bin/env python3
"""生成 ScrollWM 应用图标（Support/AppIcon.icns）。

优先使用 Support/icon-source.png（Liquid Glass 渲染）：裁掉黑边，
按 macOS 824/1024 网格贴到透明画布并做圆角遮罩。
没有源图时回退到程序绘制的三列纸带。依赖 PIL 与系统 iconutil。
"""
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
PLATE = 824  # macOS 图标网格：内容占 824/1024
RADIUS = 186  # 圆角半径（近似系统 squircle）


def rounded(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def plate_mask() -> Image.Image:
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    x0 = (CANVAS - PLATE) // 2
    rounded(
        ImageDraw.Draw(mask),
        [x0, x0, x0 + PLATE - 1, x0 + PLATE - 1],
        RADIUS,
        255,
    )
    return mask


def crop_black_frame(im: Image.Image) -> Image.Image:
    """去掉渲染图四周的实心黑底，保留 squircle 本体。"""
    rgb = im.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    minx, miny, maxx, maxy = w, h, 0, 0
    step = 2
    for y in range(0, h, step):
        for x in range(0, w, step):
            r, g, b = px[x, y]
            if r + g + b > 18:
                if x < minx:
                    minx = x
                if y < miny:
                    miny = y
                if x > maxx:
                    maxx = x
                if y > maxy:
                    maxy = y
    pad = 4
    box = (
        max(0, minx - pad),
        max(0, miny - pad),
        min(w, maxx + pad + 1),
        min(h, maxy + pad + 1),
    )
    return im.crop(box)


def from_source(path: str) -> Image.Image:
    src = Image.open(path).convert("RGBA")
    src = crop_black_frame(src)
    # 源图圆角处仍是黑像素；先缩放到底板，再用几何遮罩切透明
    fitted = src.resize((PLATE, PLATE), Image.LANCZOS)
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x0 = (CANVAS - PLATE) // 2
    img.paste(fitted, (x0, x0))
    mask = plate_mask()
    # 轻微羽化，避免圆角锯齿
    mask = mask.filter(ImageFilter.GaussianBlur(radius=0.6))
    img.putalpha(Image.composite(img.getchannel("A"), Image.new("L", img.size, 0), mask))
    return img


def build_fallback() -> Image.Image:
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    x0 = (CANVAS - PLATE) // 2
    plate = Image.new("RGBA", (PLATE, PLATE), (0, 0, 0, 0))
    pd = ImageDraw.Draw(plate)
    top, bottom = (38, 42, 56), (22, 24, 34)
    for y in range(PLATE):
        t = y / PLATE
        color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        pd.line([(0, y), (PLATE, y)], fill=color)
    mask = Image.new("L", (PLATE, PLATE), 0)
    rounded(ImageDraw.Draw(mask), [0, 0, PLATE - 1, PLATE - 1], RADIUS, 255)
    img.paste(plate, (x0, x0), mask)

    col_h = 448
    col_y = (CANVAS - col_h) // 2
    col_r = 42
    gap = 56
    mid_w, side_w = 300, 172
    mid_x = (CANVAS - mid_w) // 2

    side_color = (96, 104, 132, 255)
    focus_color = (124, 156, 255, 255)

    rounded(draw, [mid_x - gap - side_w, col_y, mid_x - gap, col_y + col_h], col_r, side_color)
    rounded(draw, [mid_x + mid_w + gap, col_y, mid_x + mid_w + gap + side_w, col_y + col_h], col_r, side_color)
    rounded(draw, [mid_x, col_y, mid_x + mid_w, col_y + col_h], col_r, focus_color)
    rounded(draw, [mid_x + 36, col_y + 40, mid_x + mid_w - 36, col_y + 96], 22, (238, 242, 255, 255))

    outer_mask = plate_mask()
    img.putalpha(Image.composite(img.getchannel("A"), Image.new("L", img.size, 0), outer_mask))
    return img


def build_master(root: str) -> Image.Image:
    source = os.path.join(root, "Support", "icon-source.png")
    if os.path.isfile(source):
        return from_source(source)
    return build_fallback()


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_icns = os.path.join(root, "Support", "AppIcon.icns")
    master = build_master(root)
    preview = os.path.join(root, "Support", "AppIcon-1024.png")
    master.save(preview)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 64, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
                master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_icns], check=True)

    print(f"已生成 {out_icns}")
    return 0


if __name__ == "__main__":
    if shutil.which("iconutil") is None:
        print("缺少 iconutil（需在 macOS 上运行）", file=sys.stderr)
        sys.exit(1)
    sys.exit(main())
