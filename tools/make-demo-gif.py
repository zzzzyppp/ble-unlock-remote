#!/usr/bin/env python3
"""
生成 BLE Unlock 的介绍动画（GIF）。

三个场景，对应 README 里最值得展示的能力：
  1. 一键解锁   —— 手机点一下，Mac 自动输入密码解开
  2. 选择密码   —— 手机端「填充密码」长按更换用哪个密码
  3. 多密码回退 —— 第一个密码不对时自动试下一个

用法:
    make-demo-gif.py [--lang en|zh] [--scale 1.0] [--out 路径] [--fps 25]
"""

import argparse
import math
import os
from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------- 主题

BG_TOP = (14, 17, 22)
BG_BOT = (20, 24, 31)
CARD = (27, 32, 39)
CARD_HI = (35, 42, 52)
FG = (232, 236, 241)
MUTED = (138, 148, 162)
DIM = (86, 95, 108)
GREEN = (39, 108, 45)
GREEN_HI = (110, 195, 115)
BLUE = (21, 101, 192)
BLUE_HI = (86, 175, 250)
AMBER = (255, 202, 40)
RED = (239, 83, 80)
BORDER = (52, 60, 73)

# 字体选择。
#
# 注意：SFNS.ttf 虽然能被 PIL 打开，但取不到 CJK 字形——汉字会渲染成空心方块。
# 所以中文版必须用真正的 CJK 字体，英文版才用 SFNS（字形更好看）。
FONT_CJK = [
    "/System/Library/Fonts/Hiragino Sans GB.ttc",     # 简体中文观感最好
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
]
FONT_LATIN = [
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
]

_fonts = {}
_FONT_FILES = FONT_LATIN


def set_lang_fonts(lang):
    """按语言选字体族。中文必须走 CJK 字体，否则汉字是方块。"""
    global _FONT_FILES
    _FONT_FILES = FONT_CJK if lang == "zh" else FONT_LATIN
    _fonts.clear()


def font(size):
    if size in _fonts:
        return _fonts[size]
    f = None
    for p in _FONT_FILES:
        if os.path.exists(p):
            try:
                f = ImageFont.truetype(p, size)
                break
            except Exception:
                pass
    if f is None:
        f = ImageFont.load_default()
    _fonts[size] = f
    return f


# ---------------------------------------------------------------- 缓动


def clamp01(x):
    return 0.0 if x < 0 else (1.0 if x > 1 else x)


def ease_out(t):
    t = clamp01(t)
    return 1 - (1 - t) ** 3


def ease_io(t):
    t = clamp01(t)
    return 3 * t * t - 2 * t * t * t


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(3))


def rgba(c, a):
    return (c[0], c[1], c[2], int(round(255 * clamp01(a))))


# ---------------------------------------------------------------- 绘制


class Scene:
    """一帧画布 + 抗锯齿圆角矩形"""

    SS = 3

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new("RGB", (w, h), BG_TOP)
        d = ImageDraw.Draw(self.img)
        for y in range(h):
            d.line([(0, y), (w, y)], fill=mix(BG_TOP, BG_BOT, y / max(1, h - 1)))

    def layer(self):
        return Image.new("RGBA", (self.w, self.h), (0, 0, 0, 0))

    def rrect(self, layer, box, radius, fill=None, outline=None, width=1):
        x0, y0, x1, y1 = box
        bw, bh = int(round(x1 - x0)), int(round(y1 - y0))
        if bw < 1 or bh < 1:
            return
        r = min(radius, bw / 2, bh / 2)
        s = self.SS
        big = Image.new("RGBA", (bw * s, bh * s), (0, 0, 0, 0))
        bd = ImageDraw.Draw(big)
        if fill is not None and outline is not None:
            bd.rounded_rectangle([0, 0, bw * s - 1, bh * s - 1], radius=r * s,
                                 fill=fill, outline=outline, width=max(1, width * s))
        elif fill is not None:
            bd.rounded_rectangle([0, 0, bw * s - 1, bh * s - 1], radius=r * s, fill=fill)
        else:
            bd.rounded_rectangle([0, 0, bw * s - 1, bh * s - 1], radius=r * s,
                                 outline=outline, width=max(1, width * s))
        big = big.resize((bw, bh), Image.LANCZOS)
        layer.alpha_composite(big, (int(round(x0)), int(round(y0))))

    def text(self, layer, xy, s, size, fill, anchor="la"):
        ImageDraw.Draw(layer).text(xy, s, font=font(size), fill=fill, anchor=anchor)

    def tw(self, s, size):
        return font(size).getbbox(s)[2]

    def put(self, layer):
        self.img.paste(Image.alpha_composite(self.img.convert("RGBA"), layer).convert("RGB"),
                       (0, 0))


# ---------------------------------------------------------------- 文案

S = {
    "en": dict(
        app="BLE Unlock",
        tagline="Tap your phone. Your Mac unlocks.",
        conn="Connecting to Mac…",
        ready="Ready to unlock",
        unlock_text="UNLOCK",
        fill="Fill: {}",
        fill_hint="(long-press to change)",
        choose="Choose a password",
        slot_names=["Current", "Old", "Backup"],
        locked_text="Locked",
        unlocked_text="Unlocked",
        typed_text="password typed automatically",
        wrong_text="wrong password",
        cap1="Tap once — the Mac types your login password",
        cap2="Long-press to pick which password to fill",
        cap3="Wrong password? It tries the next one automatically",
        badges=["HMAC-SHA256 signed", "Password stays in the Keychain",
                "Never sent over Bluetooth"],
        macname="MacBook Air",
    ),
    "zh": dict(
        app="BLE Unlock",
        tagline="手机点一下，Mac 自动解锁",
        conn="正在连接 Mac…",
        ready="准备就绪",
        unlock_text="解 锁",
        fill="填充密码：{}",
        fill_hint="（长按可更换）",
        choose="选择要填充的密码",
        slot_names=["当前密码", "旧密码", "备用"],
        locked_text="已锁定",
        unlocked_text="已解锁",
        typed_text="已自动输入登录密码",
        wrong_text="密码不对",
        cap1="点一下，Mac 自动输入登录密码",
        cap2="长按可选择要填充哪个密码",
        cap3="密码不对？自动试下一个",
        badges=["HMAC-SHA256 签名", "密码只存钥匙串", "不经蓝牙传输"],
        macname="MacBook Air",
    ),
}

# 布局
W, H = 1200, 675
PHONE = dict(x=150, y=118, w=252, h=486, r=36)
MAC = dict(x=690, y=152, w=430, h=296, r=12)

# 时间线：每幕 (名称, 时长秒)
TIMELINE = [("title", 1.5), ("unlock", 3.9), ("pick", 4.1), ("fallback", 4.7),
            ("outro", 2.4)]

SCENE_DUR = dict(TIMELINE)
CAPTION_FOR = {"unlock": "cap1", "pick": "cap2", "fallback": "cap3"}


# ---------------------------------------------------------------- 手机


def phone_button_center():
    p = PHONE
    sy = p["y"] + 12
    card_y = sy + 76
    btn_y = card_y + 92
    return (p["x"] + p["w"] // 2, btn_y + 37)


def draw_phone(c, st, t):
    p = PHONE
    L = c.layer()

    # 机身
    c.rrect(L, (p["x"] - 7, p["y"] - 7, p["x"] + p["w"] + 7, p["y"] + p["h"] + 7),
            p["r"] + 5, fill=(38, 43, 52))
    c.rrect(L, (p["x"], p["y"], p["x"] + p["w"], p["y"] + p["h"]),
            p["r"], fill=(15, 18, 22))

    sx, sy = p["x"] + 12, p["y"] + 12
    sw, sh = p["w"] - 24, p["h"] - 24
    d = ImageDraw.Draw(L)

    # 状态栏
    c.text(L, (sx + 12, sy + 16), "9:41", 13, MUTED, anchor="lm")
    d.rounded_rectangle([sx + sw - 48, sy + 13, sx + sw - 34, sy + 21], 3, fill=MUTED)
    d.rounded_rectangle([sx + sw - 30, sy + 12, sx + sw - 16, sy + 22], 3, fill=MUTED)

    # 标题
    c.text(L, (sx + sw // 2, sy + 44), st["app"], 21, FG, anchor="mm")

    # 状态卡
    cy = sy + 74
    c.rrect(L, (sx + 8, cy, sx + sw - 8, cy + 76), 12, fill=CARD)
    c.text(L, (sx + 20, cy + 12), "ypz's " + st["macname"], 13, FG)
    if st["connected"]:
        c.text(L, (sx + 20, cy + 36), st["ready"], 15, GREEN_HI)
    else:
        c.text(L, (sx + 20, cy + 36), st["conn"], 15, AMBER)

    # 主按钮
    by = cy + 94
    bh = 76
    press = st.get("pressed", 0.0)
    if st["mode"] == "unlock":
        col = mix(GREEN, (255, 255, 255), 0.18 * press)
        c.rrect(L, (sx + 8, by, sx + sw - 8, by + bh), 14, fill=col)
        c.text(L, (sx + sw // 2, by + bh // 2), st["unlock_text"], 24, FG, anchor="mm")
    else:
        c.rrect(L, (sx + 8, by, sx + sw - 8, by + bh), 14,
                fill=CARD_HI, outline=BORDER)
        label = st["fill"].format(st["slot"])
        c.text(L, (sx + sw // 2, by + 26), label, 15, FG, anchor="mm")
        c.text(L, (sx + sw // 2, by + 50), st["fill_hint"], 11, MUTED, anchor="mm")

    # 长按进度环
    if st.get("hold", 0.0) > 0:
        h = clamp01(st["hold"])
        cx, cyy = sx + sw - 36, by + bh // 2
        r = 14
        d.ellipse([cx - r, cyy - r, cx + r, cyy + r], outline=(62, 70, 84), width=3)
        d.arc([cx - r, cyy - r, cx + r, cyy + r], -90, -90 + 360 * h,
              fill=BLUE_HI, width=3)

    c.text(L, (sx + sw // 2, sy + sh - 22), st["app"], 11, DIM, anchor="mm")

    # 密码选择弹层
    if st.get("picker", 0.0) > 0:
        prog = ease_out(st["picker"])
        sheet_h = 196
        sheet_y = sy + sh - sheet_h * prog
        d.rectangle([sx, sy, sx + sw, sy + sh], fill=(0, 0, 0, int(150 * prog)))
        c.rrect(L, (sx + 4, sheet_y, sx + sw - 4, sy + sh + 20), 18, fill=(40, 47, 58))
        c.text(L, (sx + 20, sheet_y + 16), st["choose"], 13, MUTED)
        for i, name in enumerate(st["slot_names"]):
            yy = sheet_y + 46 + i * 40
            sel = (i == st["selected"])
            if sel:
                c.rrect(L, (sx + 10, yy - 6, sx + sw - 10, yy + 30), 10,
                        fill=(45, 72, 56))
            c.text(L, (sx + 24, yy + 12), ("●  " if sel else "○  ") + name, 14,
                   FG if sel else MUTED, anchor="lm")
            c.text(L, (sx + sw - 24, yy + 12), "#%d" % (i + 1), 12,
                   GREEN_HI if sel else DIM, anchor="rm")

    c.put(L)


# ---------------------------------------------------------------- Mac


def draw_mac(c, st):
    m = MAC
    L = c.layer()
    d = ImageDraw.Draw(L)

    c.rrect(L, (m["x"], m["y"], m["x"] + m["w"], m["y"] + m["h"]),
            m["r"], fill=(28, 33, 41), outline=BORDER, width=2)
    c.rrect(L, (m["x"] + 10, m["y"] + 10, m["x"] + m["w"] - 10, m["y"] + m["h"] - 10),
            6, fill=(23, 27, 34) if st["locked"] else (26, 32, 40))

    cx = m["x"] + m["w"] // 2
    d.polygon([(cx - 58, m["y"] + m["h"]), (cx + 58, m["y"] + m["h"]),
               (cx + 72, m["y"] + m["h"] + 22), (cx - 72, m["y"] + m["h"] + 22)],
              fill=(50, 57, 68))
    d.rounded_rectangle([cx - 108, m["y"] + m["h"] + 22, cx + 108, m["y"] + m["h"] + 32],
                        4, fill=(58, 66, 78))

    ix, iy = m["x"] + 10, m["y"] + 10
    iw, ih = m["w"] - 20, m["h"] - 20
    icx, icy = ix + iw // 2, iy + ih // 2

    if st["locked"]:
        lw, lh = 56, 46
        bx, by = icx - lw // 2, icy - 34
        d.rounded_rectangle([bx, by, bx + lw, by + lh], 9, outline=FG, width=4)
        d.arc([bx + 11, by - 32, bx + lw - 11, by + 16], 180, 360, fill=FG, width=4)

        fy = by + lh + 40
        fw = 210
        fx = icx - fw // 2
        c.rrect(L, (fx, fy, fx + fw, fy + 36), 8, fill=(18, 21, 26), outline=BORDER)
        for i in range(min(st.get("dots", 0), 12)):
            dx = fx + 20 + i * 15
            d.ellipse([dx, fy + 14, dx + 9, fy + 23], fill=FG)

        if st.get("shake", 0) > 0:
            s = st["shake"]
            off = math.sin(s * math.pi * 6) * 7 * (1 - s)
            c.text(L, (icx + off, fy + 52), st["wrong_text"], 13, RED, anchor="mm")
        else:
            c.text(L, (icx, fy + 52), st["locked_text"], 14, MUTED, anchor="mm")
    else:
        d.rectangle([ix, iy, ix + iw, iy + 26], fill=(34, 40, 50))
        c.text(L, (ix + 14, iy + 13), st["app"], 12, MUTED, anchor="lm")
        for i in range(6):
            yy = iy + 44 + i * 27
            d.rounded_rectangle([ix + 18, yy, ix + iw - 18, yy + 17], 5,
                                fill=(33, 39, 48))
        c.text(L, (icx, icy - 14), st["unlocked_text"], 23, GREEN_HI, anchor="mm")
        c.text(L, (icx, icy + 20), st["typed_text"], 13, MUTED, anchor="mm")

    c.put(L)


# ---------------------------------------------------------------- 特效


def draw_ble(c, progress, label):
    L = c.layer()
    d = ImageDraw.Draw(L)
    x0 = PHONE["x"] + PHONE["w"] + 12
    x1 = MAC["x"] - 12
    y0 = PHONE["y"] + PHONE["h"] // 2
    y1 = MAC["y"] + MAC["h"] // 2

    steps = 64
    pts = []
    for i in range(steps + 1):
        u = i / steps
        pts.append((lerp(x0, x1, u), lerp(y0, y1, u) - math.sin(u * math.pi) * 48))
    d.line(pts, fill=rgba(BLUE_HI, 0.25), width=2, joint="curve")

    idx = int(ease_io(progress) * steps)
    idx = max(0, min(steps, idx))
    px, py = pts[idx]
    for r, a in ((18, 0.14), (12, 0.26), (7, 0.55), (3, 1.0)):
        col = (255, 255, 255) if r <= 3 else BLUE_HI
        d.ellipse([px - r, py - r, px + r, py + r], fill=rgba(col, a))

    if label:
        c.text(L, ((x0 + x1) / 2, min(y0, y1) - 58), label, 13, BLUE_HI, anchor="mm")
    c.put(L)


def draw_ripple(c, xy, prog):
    if prog <= 0 or prog >= 1:
        return
    L = c.layer()
    d = ImageDraw.Draw(L)
    r = lerp(12, 52, ease_out(prog))
    a = 1 - prog
    d.ellipse([xy[0] - r, xy[1] - r, xy[0] + r, xy[1] + r],
              outline=rgba((255, 255, 255), a * 0.85), width=3)
    d.ellipse([xy[0] - 7, xy[1] - 7, xy[0] + 7, xy[1] + 7],
              fill=rgba((255, 255, 255), a * 0.9))
    c.put(L)


def draw_caption(c, text, alpha):
    if alpha <= 0.02:
        return
    L = c.layer()
    size = 26
    tw = c.tw(text, size)
    x0, x1 = (W - tw) / 2 - 28, (W + tw) / 2 + 28
    y0, y1 = H - 78, H - 22
    c.rrect(L, (x0, y0, x1, y1), 15, fill=rgba(CARD, 0.94 * alpha))
    c.text(L, (W / 2, (y0 + y1) / 2 + 1), text, size, rgba(FG, alpha), anchor="mm")
    c.put(L)


def draw_center_title(c, st, alpha, y=None):
    if alpha <= 0.02:
        return
    L = c.layer()
    yy = H // 2 - 110 if y is None else y
    c.text(L, (W / 2, yy), st["app"], 46, rgba(FG, alpha), anchor="mm")
    c.text(L, (W / 2, yy + 46), st["tagline"], 20, rgba(MUTED, alpha), anchor="mm")
    c.put(L)


def draw_badges(c, st, alpha):
    if alpha <= 0.02:
        return
    L = c.layer()
    size = 14
    widths = [c.tw(s, size) + 36 for s in st["badges"]]
    total = sum(widths) + 20 * (len(widths) - 1)
    x = (W - total) / 2
    y = H // 2 + 92
    for s, w in zip(st["badges"], widths):
        c.rrect(L, (x, y, x + w, y + 38), 19,
                fill=rgba(CARD, 0.95 * alpha), outline=rgba(BORDER, alpha))
        c.text(L, (x + w / 2, y + 20), s, size, rgba(MUTED, alpha), anchor="mm")
        x += w + 20
    c.put(L)


# ---------------------------------------------------------------- 每幕状态


def state_unlock(t, st):
    """点一下 -> 传输 -> 输入密码 -> 解锁"""
    st["mode"] = "unlock"
    st["connected"] = t > 0.25
    if 0.85 <= t < 1.05:
        st["pressed"] = 1 - abs((t - 0.95) / 0.1)

    out = dict(ble=False, ble_prog=0, ripple=None)

    if 0.85 <= t < 1.15:
        out["ripple"] = ((phone_button_center()), (t - 0.85) / 0.3)
    if t >= 0.95:
        out["ble"] = True
        out["ble_prog"] = (t - 0.95) / 1.1
        out["ble_label"] = st["conn"] if t < 1.7 else None
    if t >= 2.1:
        st["dots"] = min(int((t - 2.1) / 0.085), 8)
    if t >= 3.1:
        st["locked"] = False
    out["caption_a"] = fade(t, SCENE_DUR["unlock"])
    return out


def state_pick(t, st):
    """长按 -> 弹层 -> 选第二个 -> 填充"""
    st["mode"] = "fill"
    st["connected"] = True
    st["slot"] = st["slot_names"][0]

    out = dict(ble=False, ble_prog=0, ripple=None)

    if t < 0.8:
        st["hold"] = t / 0.8
    if t >= 0.8:
        st["hold"] = 0
        st["picker"] = min(1.0, (t - 0.8) / 0.35)
    if t >= 1.55:
        st["selected"] = 1
        st["slot"] = st["slot_names"][1]
    if t >= 1.95:
        st["picker"] = max(0.0, 1 - (t - 1.95) / 0.3)
    if t >= 2.35:
        st["dots"] = min(int((t - 2.35) / 0.09), 8)
    if t >= 3.35:
        st["locked"] = False
    out["caption_a"] = fade(t, SCENE_DUR["pick"])
    return out


def state_fallback(t, st):
    """第一个密码不对 -> 抖动 -> 自动试第二个 -> 成功"""
    st["mode"] = "fill"
    st["connected"] = True
    st["slot"] = st["slot_names"][1]

    out = dict(ble=False, ble_prog=0, ripple=None)

    if t >= 0.6:
        st["dots"] = min(int((t - 0.6) / 0.08), 8)
    if 1.6 <= t < 2.5:
        st["shake"] = (t - 1.6) / 0.9
    if t >= 2.5:
        st["dots"] = 0
        st["shake"] = 0
    if t >= 3.0:
        st["dots"] = min(int((t - 3.0) / 0.08), 8)
    if t >= 4.0:
        st["locked"] = False
    out["caption_a"] = fade(t, SCENE_DUR["fallback"])
    return out


def state_outro(t, st):
    """结尾：标题 + 三条安全要点，无字幕"""
    st["mode"] = "unlock"
    st["connected"] = True
    st["locked"] = False
    return dict(ble=False, ble_prog=0, ripple=None, ble_label=None,
                caption="", cap_a=0.0,
                title_a=clamp01(t / 0.7),
                badges_a=clamp01((t - 0.45) / 0.7))


def fade(t, dur, edge=0.35):
    if t < edge:
        return t / edge
    if t > dur - edge:
        return max(0.0, (dur - t) / edge)
    return 1.0


def fresh_state(st):
    """每幕开始时的状态"""
    st["locked"] = True
    st["dots"] = 0
    st["shake"] = 0
    st["picker"] = 0.0
    st["selected"] = 0
    st["hold"] = 0.0
    st["pressed"] = 0.0
    st["slot"] = st["slot_names"][0]
    st["mode"] = "unlock"
    st["connected"] = False


# ---------------------------------------------------------------- 渲染


def render(lang, out_path, scale=1.0, fps=25, optimize=True,
           global_palette=True, colors=128, dither=Image.NONE):
    set_lang_fonts(lang)
    st = dict(S[lang])
    frames = []
    raw = []
    made = 0

    for name, dur in TIMELINE:
        fresh_state(st)
        n = int(round(dur * fps))
        for i in range(n):
            t = i / fps
            c = Scene(W, H)

            fx = dict(ble=False, ble_prog=0, ripple=None, caption="", cap_a=0,
                      ble_label=None, title_a=0.0, badges_a=0.0)

            if name == "title":
                fx["title_a"] = min(1.0, t / 0.6) * (1.0 if t < dur - 0.5
                                                    else max(0.0, (dur - t) / 0.5))
                draw_center_title(c, st, fx["title_a"])
            else:
                fn = {"unlock": state_unlock, "pick": state_pick,
                      "fallback": state_fallback, "outro": state_outro}[name]
                fx = fn(t, st)
                # 字幕按场景名取，别再用下标——下标和 TIMELINE 一旦不同步就会串幕
                fx.setdefault("caption", CAPTION_FOR.get(name, ""))

                draw_phone(c, st, t)
                draw_mac(c, st)

                if fx.get("ble"):
                    draw_ble(c, fx["ble_prog"], fx.get("ble_label"))
                if fx.get("ripple"):
                    draw_ripple(c, fx["ripple"][0], fx["ripple"][1])

                if name == "outro":
                    draw_center_title(c, st, fx["title_a"])
                    draw_badges(c, st, fx["badges_a"])

                if fx.get("caption"):
                    draw_caption(c, st[fx["caption"]], fx.get("caption_a", 1.0))

            img = c.img
            if scale != 1.0:
                img = img.resize((int(W * scale), int(H * scale)), Image.LANCZOS)
            raw.append(img.copy())
            if not global_palette:
                frames.append(img.convert("P", palette=Image.ADAPTIVE, colors=colors))
            made += 1

    # 全局调色板：所有帧共用一张调色板，GIF 压缩率远高于逐帧自适应调色板，
    # 画面是深色 UI、颜色本来就集中，视觉损失很小。
    if global_palette:
        base = raw[len(raw) // 3].convert("P", palette=Image.ADAPTIVE, colors=colors)
        for img in raw:
            frames.append(img.quantize(palette=base, dither=dither))

    # optimize=True 会合并完全相同的帧，导致"第 N 帧"不再对应第 N/fps 秒。
    # 检查关键画面时要按时间戳取原始帧，所以这里把 raw 一并返回。
    frames[0].save(out_path, save_all=True, append_images=frames[1:],
                   duration=int(round(1000 / fps)), loop=0, optimize=optimize,
                   disposal=2)
    return made, raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", default="en", choices=["en", "zh"])
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--fps", type=int, default=18)
    ap.add_argument("--out", default=None)
    ap.add_argument("--no-optimize", action="store_true",
                    help="不做帧合并，输出体积更大但帧号与时间一一对应")
    ap.add_argument("--dump-frames", default=None,
                    help="导出指定时刻的画面到该目录，用于人工检查")
    ap.add_argument("--at", type=float, nargs="*", default=[],
                    help="要导出的场景内时刻（秒），如 --at 1.0 3.0")
    ap.add_argument("--colors", type=int, default=128, help="调色板颜色数")
    ap.add_argument("--dither", action="store_true",
                    help="开启抖动（渐变背景上会显著增大体积，默认关闭）")
    ap.add_argument("--per-frame-palette", action="store_true",
                    help="逐帧自适应调色板（体积更大，仅对比用）")
    a = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = a.out or os.path.join(root, "docs", "demo-%s.gif" % a.lang)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    n, raw = render(a.lang, out, a.scale, a.fps, optimize=not a.no_optimize,
                    global_palette=not a.per_frame_palette, colors=a.colors,
                    dither=Image.FLOYDSTEINBERG if a.dither else Image.NONE)
    mb = os.path.getsize(out) / 1024 / 1024
    print("  %s：%d 帧，%.2f MB" % (out, n, mb))

    if a.dump_frames:
        os.makedirs(a.dump_frames, exist_ok=True)
        starts, acc = [], 0.0
        for nm, d in TIMELINE:
            starts.append((nm, acc, d))
            acc += d
        for nm, start, d in starts:
            for frac in a.at:
                if frac > d:
                    continue
                idx = int(round((start + frac) * a.fps))
                if 0 <= idx < len(raw):
                    fp = os.path.join(a.dump_frames,
                                      "%s-%04.1fs.png" % (nm, frac))
                    raw[idx].save(fp)
                    # 顺带打印一份像素签名，便于核对"导出的确实是那一刻"
                    sig = sum(raw[idx].convert("L").resize((16, 9)).getdata())
                    print("    %-8s @%4.1fs -> 帧#%-4d %s  sig=%d"
                          % (nm, frac, idx, os.path.basename(fp), sig))


if __name__ == "__main__":
    main()
