#!/usr/bin/env python3
"""生成 ScrollWM 应用图标（Support/AppIcon.icns）。

设计：macOS 圆角方块规格（824/1024 网格），深色底 + 三列纸带，
中间列高亮表示焦点列。依赖 PIL 与系统 iconutil。
"""
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

CANVAS = 1024
PLATE = 824          # macOS 图标网格：内容占 824/1024
RADIUS = 186         # 圆角半径（近似系统 squircle）


def rounded(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def build_master() -> Image.Image:
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 底板：深石板色，上浅下深的纵向渐变
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

    # 三列纸带：中间焦点列亮、两侧暗列被"停靠"在边缘
    col_h = 448
    col_y = (CANVAS - col_h) // 2
    col_r = 42
    gap = 56
    mid_w, side_w = 300, 172
    mid_x = (CANVAS - mid_w) // 2

    side_color = (96, 104, 132, 255)
    focus_color = (124, 156, 255, 255)

    # 左右暗列（探出底板边缘一点，暗示纸带向两侧延伸）
    rounded(draw, [mid_x - gap - side_w, col_y, mid_x - gap, col_y + col_h], col_r, side_color)
    rounded(draw, [mid_x + mid_w + gap, col_y, mid_x + mid_w + gap + side_w, col_y + col_h], col_r, side_color)
    # 焦点列
    rounded(draw, [mid_x, col_y, mid_x + mid_w, col_y + col_h], col_r, focus_color)
    # 焦点列内的窗口标题条
    rounded(draw, [mid_x + 36, col_y + 40, mid_x + mid_w - 36, col_y + 96], 22, (238, 242, 255, 255))

    # 再次用底板圆角裁掉探出的部分，保持规范外形
    outer_mask = Image.new("L", (CANVAS, CANVAS), 0)
    rounded(
        ImageDraw.Draw(outer_mask),
        [x0, x0, x0 + PLATE - 1, x0 + PLATE - 1],
        RADIUS,
        255,
    )
    img.putalpha(Image.composite(img.getchannel("A"), Image.new("L", img.size, 0), outer_mask))
    return img


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_icns = os.path.join(root, "Support", "AppIcon.icns")
    master = build_master()

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
