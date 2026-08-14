#!/usr/bin/env python3
"""生成 ScrollWM 应用图标（Support/Assets.car + Support/AppIcon.icns）。

程序化绘制克制的 Liquid Glass 图标：磨砂玻璃底板 + 三列窗口母题。
浅色 / 深色（luminosity dark）两套外观；深色变体需要 Asset Catalog，
由 actool 编译成 Assets.car（icns 不支持深色外观，仅作回退）。
依赖 PIL 与系统 iconutil / actool。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
PLATE = 824  # macOS 图标网格：内容占 824/1024
RADIUS = 186  # 圆角半径（近似系统 squircle）
SS = 2  # 超采样倍数，缩小后得到平滑边缘

# 三列窗口母题的几何（画布坐标，绘制时按 SS 放大）
COL_H = 448
COL_R = 42
GAP = 56
MID_W, SIDE_W = 300, 172

PALETTES = {
    False: {  # 浅色外观：银底
        "bg_top": (238, 241, 246),
        "bg_bottom": (200, 206, 218),
        "tint": (110, 140, 255, 14),
        "sheen_alpha": 80,
        "rim_alpha": 150,
        "side_fill": (255, 255, 255, 190),
        "side_stroke": (95, 105, 130, 110),
        "side_grip": (95, 105, 135, 110),
        "side_shadow": (30, 40, 70, 48),
        "mid_fill": (253, 254, 255, 250),
        "mid_stroke": (70, 110, 225, 220),
        "mid_grip": (70, 110, 225, 245),
        "mid_shadow": (40, 55, 110, 85),
        "specular_alpha": 26,
    },
    True: {  # 深色外观：石墨玻璃
        "bg_top": (52, 54, 65),
        "bg_bottom": (28, 30, 39),
        "tint": (100, 130, 255, 26),
        "sheen_alpha": 38,
        "rim_alpha": 60,
        "side_fill": (180, 190, 220, 60),
        "side_stroke": (205, 215, 245, 60),
        "side_grip": (205, 215, 245, 70),
        "side_shadow": (0, 0, 0, 80),
        "mid_fill": (58, 62, 80, 245),
        "mid_stroke": (130, 160, 255, 190),
        "mid_grip": (130, 160, 255, 235),
        "mid_shadow": (0, 0, 0, 120),
        "specular_alpha": 16,
    },
}


def plate_box(offset=0):
    x0 = (CANVAS - PLATE) // 2 + offset
    return [x0, x0, x0 + PLATE - 1 - offset * 2, x0 + PLATE - 1 - offset * 2]


def draw_master(dark: bool) -> Image.Image:
    p = PALETTES[dark]
    s = CANVAS * SS
    x0 = (CANVAS - PLATE) // 2 * SS
    plate_box_ss = [x0, x0, x0 + PLATE * SS - 1, x0 + PLATE * SS - 1]

    # 底板：极缓和的纵向渐变 + 中心一点点品牌蓝
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    plate = Image.new("RGBA", (PLATE * SS, PLATE * SS))
    pd = ImageDraw.Draw(plate)
    h = PLATE * SS
    for y in range(h):
        t = y / h
        color = tuple(round(p["bg_top"][i] + (p["bg_bottom"][i] - p["bg_top"][i]) * t) for i in range(3)) + (255,)
        pd.line([(0, y), (h, y)], fill=color)
    tint = Image.new("RGBA", plate.size, (0, 0, 0, 0))
    ImageDraw.Draw(tint).ellipse(
        [-h * 0.25, -h * 0.35, h * 1.25, h * 1.1], fill=p["tint"]
    )
    tint = tint.filter(ImageFilter.GaussianBlur(radius=PLATE * SS // 8))
    plate = Image.alpha_composite(plate, tint)
    img.paste(plate, (x0, x0))

    # 玻璃上缘高光：自上而下衰减的白色薄雾
    sheen = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sheen_h = int(h * 0.46)
    for y in range(sheen_h):
        a = round(p["sheen_alpha"] * (1 - y / sheen_h) ** 1.6)
        sd.line([(x0, x0 + y), (x0 + h, x0 + y)], fill=(255, 255, 255, a))
    img = Image.alpha_composite(img, sheen)

    # 左上柔和高光斑，液体玻璃的“湿润感”，幅度压低
    spec = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(spec).ellipse(
        [x0 + h * 0.08, x0 - h * 0.10, x0 + h * 0.72, x0 + h * 0.30],
        fill=(255, 255, 255, p["specular_alpha"]),
    )
    spec = spec.filter(ImageFilter.GaussianBlur(radius=PLATE * SS // 10))
    img = Image.alpha_composite(img, spec)

    # 三列窗口卡片
    col_y = (CANVAS - COL_H) // 2 * SS
    col_h, col_r = COL_H * SS, COL_R * SS
    gap, mid_w, side_w = GAP * SS, MID_W * SS, SIDE_W * SS
    mid_x = (CANVAS - MID_W) // 2 * SS

    def card(box, fill, stroke, grip, shadow_color, shadow_blur):
        layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle(
            [box[0], box[1] + 9 * SS, box[2], box[3] + 9 * SS],
            radius=col_r, fill=shadow_color,
        )
        layer = layer.filter(ImageFilter.GaussianBlur(radius=shadow_blur))
        body = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        bd = ImageDraw.Draw(body)
        bd.rounded_rectangle(box, radius=col_r, fill=fill, outline=stroke, width=max(2, SS))
        # 顶部握条：窗口标题栏的极简暗示
        bd.rounded_rectangle(
            [box[0] + 24 * SS, box[1] + 22 * SS, box[0] + 24 * SS + 52 * SS, box[1] + 34 * SS],
            radius=6 * SS, fill=grip,
        )
        layer = Image.alpha_composite(layer, body)
        return layer

    side_l = [mid_x - gap - side_w, col_y, mid_x - gap, col_y + col_h]
    side_r = [mid_x + mid_w + gap, col_y, mid_x + mid_w + gap + side_w, col_y + col_h]
    mid = [mid_x, col_y, mid_x + mid_w, col_y + col_h]

    for side in (side_l, side_r):
        img = Image.alpha_composite(img, card(side, p["side_fill"], p["side_stroke"], p["side_grip"], p["side_shadow"], 7 * SS))
    img = Image.alpha_composite(img, card(mid, p["mid_fill"], p["mid_stroke"], p["mid_grip"], p["mid_shadow"], 10 * SS))

    # 玻璃内沿：一圈极细亮边，上亮下暗
    rim = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    rd.rounded_rectangle(plate_box_ss, radius=RADIUS * SS, outline=(255, 255, 255, p["rim_alpha"]), width=2 * SS)
    rd.rounded_rectangle(
        plate_box_ss, radius=RADIUS * SS,
        outline=(20, 24, 40, max(12, p["rim_alpha"] // 5)), width=SS,
    )
    img = Image.alpha_composite(img, rim)

    # 缩小抗锯齿 + squircle 遮罩
    img = img.resize((CANVAS, CANVAS), Image.LANCZOS)
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(mask).rounded_rectangle(plate_box(), radius=RADIUS, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius=0.6))
    img.putalpha(Image.composite(img.getchannel("A"), Image.new("L", img.size, 0), mask))
    return img


# macOS 图标全部槽位（浅色 + 深色成对出现）
SLOTS = [
    ("16x16", 1), ("16x16", 2),
    ("32x32", 1), ("32x32", 2),
    ("128x128", 1), ("128x128", 2),
    ("256x256", 1), ("256x256", 2),
    ("512x512", 1), ("512x512", 2),
]


def build_iconset(masters, out_dir: str) -> None:
    appiconset = os.path.join(out_dir, "AppIcon.appiconset")
    os.makedirs(appiconset)
    images = []
    for size, scale in SLOTS:
        px = int(size.split("x")[0]) * scale
        for dark, suffix in ((False, "light"), (True, "dark")):
            name = f"icon-{size}@{scale}x-{suffix}.png"
            masters[dark].resize((px, px), Image.LANCZOS).save(os.path.join(appiconset, name))
            entry = {"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": size}
            if dark:
                entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
            images.append(entry)
    with open(os.path.join(appiconset, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    support = os.path.join(root, "Support")

    light = draw_master(dark=False)
    dark = draw_master(dark=True)
    light.save(os.path.join(support, "AppIcon-1024.png"))
    dark.save(os.path.join(support, "AppIcon-dark-1024.png"))

    # 深色外观适配：Asset Catalog（Assets.car）
    have_car = False
    if shutil.which("xcrun"):
        with tempfile.TemporaryDirectory() as tmp:
            xcassets = os.path.join(tmp, "AppIcon.xcassets")
            os.makedirs(xcassets)
            with open(os.path.join(xcassets, "Contents.json"), "w") as f:
                json.dump({"info": {"author": "xcode", "version": 1}}, f)
            build_iconset({False: light, True: dark}, xcassets)
            out = os.path.join(tmp, "out")
            os.makedirs(out)
            proc = subprocess.run(
                ["xcrun", "actool", "--compile", out,
                 "--minimum-deployment-target", "14.0",
                 "--platform", "macosx", "--app-icon", "AppIcon",
                 "--output-partial-info-plist", os.path.join(tmp, "partial.plist"),
                 xcassets],
                capture_output=True,
            )
            if proc.returncode == 0 and os.path.isfile(os.path.join(out, "Assets.car")):
                shutil.copy(os.path.join(out, "Assets.car"), os.path.join(support, "Assets.car"))
                have_car = True
            else:
                print("actool 编译失败（深色外观不可用，仅输出 icns）：", file=sys.stderr)
                print(proc.stderr.decode(errors="replace") or proc.stdout.decode(errors="replace"), file=sys.stderr)

    # icns 回退（不支持深色外观）
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
                light.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(support, "AppIcon.icns")], check=True)

    print(f"已生成 AppIcon（liquid glass，{'含深色外观' if have_car else '仅 icns 回退'}）")
    return 0


if __name__ == "__main__":
    if shutil.which("iconutil") is None:
        print("缺少 iconutil（需在 macOS 上运行）", file=sys.stderr)
        sys.exit(1)
    sys.exit(main())
