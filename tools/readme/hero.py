#!/usr/bin/env python3
"""Animated README hero for Keeplight (stdlib only):  python3 -I tools/readme/hero.py

Writes docs/images/hero-light.svg and docs/images/hero-dark.svg: one SMIL timeline (no script, so it
plays inside GitHub's <img>), a calm 7.4 s loop like Snapline's hero, telling the product story on
the owner's desk (a Mac in clamshell mode and one DDC monitor, so the menu bar and the panel are on
the screen that gets dimmed):

  1. the pointer opens Keeplight's panel from the menu bar glyph;
  2. it drags the capsule slider from 72 to 0: down to about 19 the monitor's own backlight dims;
     below that the backlight stays at its minimum and the picture is dimmed further
     (docs/design/v4-keeplight.md §6a: `DimmingCurve.handover` = 3/16);
  3. it picks 3008 × 1692 from the resolution chip: the screen blanks, everything gets smaller,
     the panel locks, the glyph turns into its pending form with ` Keep?`, and the Keep card asks
     `Keep 3008 × 1692?`;
  4. nobody answers: the Fuse's 15 red dots go out from the right, the screen blanks again, the old
     resolution is back and the card says `Reverted`;
  5. the panel closes and the screen comes back up for the next loop.

Two captions (not app UI, so they sit above the dimming) name what step 2 and 4 show. Everything is
hand-written geometry taken from the app's tokens (Design/Tokens.swift, docs/design/v5-panel.md,
Overlays/KeepCard.swift) and its offscreen renders (scripts/render.sh); no screenshot, nothing
traced. Palette: ink #111113 / #F5F5F3, the panel's own greys, `paper.raised` for the captions, and
red only for lit Fuse dots (the Keep card is always dark, so its red is #FF4438 in both themes, as
in the app). The hero is sped up: here the Fuse burns 15 dots in 1.8 s; in the app they span the
revert time (15 s, or 30 s in Settings) and a mode change blanks the screen for longer. The dimming is
stylised (a black veil, 0 → .25 down to the handover, → .45 at 0 in light).
"""
import math
import os

W, H = 960, 540
T = 7.4                    # loop length, s
MENU = 24                  # menu bar height
S2 = 2560 / 3008           # 2560 × 1440 → 3008 × 1692: everything gets this much smaller
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"

# Easing curves from Design/Tokens.swift (`out`, `in`, `hand`) and linear.
OUT, IN, HAND, LINEAR = "0 0 0.2 1", "0.4 0 1 1", "0.42 0 0.58 1", "0 0 1 1"

THEMES = {
    "light": dict(
        bg0="#E6E6E2", bg1="#D2D2CD", glow="#FFFFFF", glow_op=".75",
        menu="#F7F7F5", menu_op=".86", menu_ink="#111113",
        win="#FFFFFF", win_edge="#0000001F", title="#F3F3F1", line="#E6E6E2", dots="#C9C9C5",
        panel="#F0F0F0", panel_edge="#11111326", module="#F6F6F6", module_edge="#1111130F",
        track="#D8D8D8", fill="#FFFFFF", fill_edge="#11111324", ink="#111113", ink2="#5E5E62",
        wash="#11111314", wash_pressed="#1111132E", popup="#F4F4F2", popup_edge="#11111326",
        highlight="#1111131F", caption="#FFFFFF", caption_op=".94", caption_edge="#1111131F",
        caption_ink="#5E5E62", shadow=".18", dim=".45"),
    "dark": dict(
        bg0="#1E1E21", bg1="#0D0D0F", glow="#FFFFFF", glow_op=".08",
        menu="#232326", menu_op=".86", menu_ink="#F5F5F3",
        win="#29292C", win_edge="#FFFFFF1F", title="#313134", line="#3B3B3F", dots="#55555A",
        panel="#0A0A0A", panel_edge="#FFFFFF24", module="#1D1D20", module_edge="#FFFFFF12",
        track="#454547", fill="#FFFFFF", fill_edge="#00000000", ink="#F5F5F3", ink2="#A3A3A8",
        wash="#F5F5F314", wash_pressed="#F5F5F333", popup="#2A2A2D", popup_edge="#FFFFFF24",
        highlight="#FFFFFF24", caption="#161618", caption_op=".94", caption_edge="#FFFFFF24",
        caption_ink="#A3A3A8", shadow=".5", dim=".42"),
}

# The Keep card is an always-dark instrument plate (Palette.Instrument).
PLATE, PLATE_EDGE, SIGNAL, SPENT = "#060607", "#FFFFFF1F", "#FF4438", "#8E8E93"


def fmt(v):
    if isinstance(v, str):
        return v
    if isinstance(v, tuple):
        return " ".join(fmt(x) for x in v)
    return f"{v:.2f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v)


class Track:
    """Keyframes over the whole loop: add(t, value, ease) eases from the previous key into this one.
    jump(t, value) switches at t (the old value holds up to t)."""

    def __init__(self, v0):
        self.keys = [(0.0, v0, LINEAR)]

    def add(self, t, v, ease=OUT):
        last_t, last_v, _ = self.keys[-1]
        assert t >= last_t, (t, last_t)
        if t > last_t:
            self.keys.append((t, v, ease))
        return self

    def hold(self, t):
        return self.add(t, self.keys[-1][1], LINEAR)

    def jump(self, t, v):
        self.hold(t)
        return self.add(t + 0.002, v, LINEAR)

    def svg(self, attr, tag="animate", extra=""):
        keys = list(self.keys)
        if keys[-1][0] < T:
            keys.append((T, keys[-1][1], LINEAR))
        times = ";".join(f"{t / T:.5f}" for t, _, _ in keys)
        values = ";".join(fmt(v) for _, v, _ in keys)
        splines = ";".join(e for _, _, e in keys[1:])
        name = f'attributeName="{attr}"' if tag == "animate" else f'attributeName="transform" type="{attr}"'
        return (f'<{tag} {name} dur="{T:g}s" repeatCount="indefinite" calcMode="spline" '
                f'keyTimes="{times}" values="{values}" keySplines="{splines}"{extra}/>')


def discrete(attr, changes, v0):
    """A value that switches at the given times: changes = [(t, value), ...]."""
    times = ["0"] + [f"{t / T:.5f}" for t, _ in changes]
    values = [fmt(v0)] + [fmt(v) for _, v in changes]
    return (f'<animate attributeName="{attr}" dur="{T:g}s" repeatCount="indefinite" calcMode="discrete" '
            f'keyTimes="{";".join(times)}" values="{";".join(values)}"/>')


def fade(spans, base=0.0, ramp=0.16):
    """Opacity track: visible (1) during each (start, end) span, ramping over `ramp` s."""
    tr = Track(base)
    for start, end in spans:
        tr.hold(start).add(start + ramp, 1.0, OUT).hold(end).add(end + ramp, 0.0, IN)
    return tr


def text(x, y, s, size=13, fill=None, weight=400, anchor="start", extra="", anim=""):
    """A line of text; no `fill` inherits it (the percent's group switches it)."""
    nums = ' style="font-variant-numeric: tabular-nums"' if any(ch.isdigit() for ch in s) else ""
    paint = f' fill="{fill}"' if fill else ""
    return (f'<text x="{fmt(x)}" y="{fmt(y)}" font-family="{FONT}" font-size="{fmt(size)}" font-weight="{weight}"'
            f'{paint} text-anchor="{anchor}"{nums}{extra}>{anim}{s}</text>')


# ---------------------------------------------------------------------------------------- timeline

T_PANEL = 0.40             # click on the glyph: the panel opens (160 ms)
T_DRAG0, T_DRAG1 = 0.90, 2.10
T_CHIP, T_PICK = 2.50, 2.90
T_SWAP1 = 3.10             # mid-blank: 3008 × 1692 is on screen
T_CARD = 3.26
T_FUSE, DOT = 3.50, 0.12   # first dot goes out at T_FUSE + DOT, the last at T_FUSE + 15 × DOT
T_SWAP2 = T_FUSE + 15 * DOT + 0.24   # mid-blank: back to 2560 × 1440, card says Reverted
T_CARD_OUT = T_SWAP2 + 0.16 + 0.70
T_CLOSE = 6.60             # panel closes, the screen comes back up
T_RESET = 6.80             # slider back at 72 while nobody sees it

LEVEL0 = 0.72
HANDOVER = 3 / 16          # DimmingCurve.handover


def ease_hand(u):
    """cubic-bezier(.42, 0, .58, 1) — the `hand` curve — solved for y at x = u."""
    lo, hi = 0.0, 1.0
    for _ in range(40):
        s = (lo + hi) / 2
        x = 3 * (1 - s) ** 2 * s * 0.42 + 3 * (1 - s) * s ** 2 * 0.58 + s ** 3
        lo, hi = (s, hi) if x < u else (lo, s)
    s = (lo + hi) / 2
    return 3 * (1 - s) * s ** 2 + s ** 3


def level_at(t):
    if t <= T_DRAG0:
        return LEVEL0
    if t >= T_DRAG1:
        return 0.0
    return LEVEL0 * (1 - ease_hand((t - T_DRAG0) / (T_DRAG1 - T_DRAG0)))


def dim_of(level, dim_max):
    """Stylised screen darkness: the backlight's share down to the handover, the picture's below."""
    first = 0.30 * dim_max / 0.55
    if level >= HANDOVER:
        return first * (LEVEL0 - level) / (LEVEL0 - HANDOVER)
    return first + (dim_max - first) * (HANDOVER - level) / HANDOVER


SAMPLES = [T_DRAG0 + i * (T_DRAG1 - T_DRAG0) / 36 for i in range(37)]
T_CROSS = next(t for t in SAMPLES if level_at(t) <= HANDOVER)

# ---------------------------------------------------------------------------------------- geometry

PW, PH = 320, 158                      # panel, 1 display (v5 §1)
GLYPH_X = 760                          # status item box (18 × 18) at (GLYPH_X, 3)
PX, PY = GLYPH_X + 9 - PW / 2, MENU + 4
CX = PX + 18                           # module content left (inset 6 + padding 12)
TRACK = (CX, PY + 48, 246, 24)         # capsule track (v5 §3)
CHIP = (CX, PY + 80, 116, 24)


def fill_width(level):
    return 24 + 222 * level


def percent_x():
    return PX + PW - 18


CARD_K = 0.9                           # the Keep card (340 × 132) at this scale
CARD_W, CARD_H = 340 * CARD_K, 132 * CARD_K
CARD_X, CARD_Y = (W - CARD_W) / 2, H * 0.36   # top edge at 36 % of the screen (Shell.swift)

MENU_POP = (CHIP[0] - 4, CHIP[1] + CHIP[3] + 2, 156, 108)
ROW0_Y = MENU_POP[1] + 5


# ---------------------------------------------------------------------------------------- parts

def wallpaper(c):
    return (f'<rect width="{W}" height="{H}" fill="url(#bg)"/>'
            f'<circle cx="{W / 2}" cy="{H + 40}" r="470" fill="url(#glow)"/>')


def window(c, x, y, w, h, lines=(0.62, 0.78, 0.45, 0.7)):
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{c["win"]}" stroke="{c["win_edge"]}" filter="url(#shadow)"/>',
           f'<path d="M{x + 1},{y + 29} V{y + 10} Q{x + 1},{y + 1} {x + 10},{y + 1} H{x + w - 10} Q{x + w - 1},{y + 1} {x + w - 1},{y + 10} V{y + 29} Z" fill="{c["title"]}"/>']
    out += [f'<circle cx="{x + 16 + 14 * k}" cy="{y + 15}" r="4.5" fill="{c["dots"]}"/>' for k in range(3)]
    out += [f'<rect x="{x + 20}" y="{y + 52 + 18 * k}" width="{(w - 40) * f:.1f}" height="7" rx="3.5" fill="{c["line"]}"/>'
            for k, f in enumerate(lines)]
    return "".join(out)


def scaled(anchor_x, anchor_y, body, sx=True):
    """`body` scaled by S2 about (anchor_x, anchor_y) while 3008 × 1692 is on screen."""
    to = f"{S2:.4f} {S2:.4f}" if sx else f"1 {S2:.4f}"
    anim = (f'<animateTransform attributeName="transform" type="scale" dur="{T:g}s" repeatCount="indefinite" '
            f'calcMode="discrete" keyTimes="0;{T_SWAP1 / T:.5f};{T_SWAP2 / T:.5f}" values="1 1;{to};1 1"/>')
    return (f'<g transform="translate({fmt(anchor_x)} {fmt(anchor_y)})"><g>{anim}'
            f'<g transform="translate({fmt(-anchor_x)} {fmt(-anchor_y)})">{body}</g></g></g>')


def glyph(c):
    """StatusGlyph (Design/Glyphs.swift) in its 18 × 18 box, y down: frame (2, 4.25, 14, 9.5), r 2.25,
    line 1.5; the light a half-disc r 3.25 on the frame's inner bottom edge; pending: the light as a
    1 pt outline and the title ` Keep?`."""
    x, y = GLYPH_X, 3
    cx, cy = x + 9, y + 4.25 + 9.5 - 0.75
    half = f"M{cx - 3.25},{cy} A3.25,3.25 0 0 1 {cx + 3.25},{cy} Z"
    on = [(T_SWAP1, 1), (T_SWAP2, 0)]      # pending form shown
    off = [(T_SWAP1, 0), (T_SWAP2, 1)]     # idle form shown
    selected = Track(0.0).hold(T_PANEL).add(T_PANEL + 0.06, 1.0, OUT).hold(T_CLOSE).add(T_CLOSE + 0.12, 0.0, IN)
    return (f'<rect x="{x - 4}" y="2" width="26" height="20" rx="5" fill="{c["highlight"]}" opacity="0">'
            + selected.svg("opacity") + discrete("width", [(T_SWAP1, 70), (T_SWAP2, 26)], 26) + "</rect>"
            + f'<rect x="{x + 2}" y="{y + 4.25}" width="14" height="9.5" rx="2.25" fill="none" stroke="{c["menu_ink"]}" stroke-width="1.5"/>'
            + f'<path d="{half}" fill="{c["menu_ink"]}">{discrete("opacity", off, 1)}</path>'
            + f'<path d="{half}" fill="none" stroke="{c["menu_ink"]}" stroke-width="1" opacity="0">{discrete("opacity", on, 0)}</path>'
            + text(x + 22, 16.5, "Keep?", 13, c["menu_ink"], 500, extra=' opacity="0"', anim=discrete("opacity", on, 0)))


def menubar_right(c):
    bars = (f'<rect x="842" y="7" width="16" height="10" rx="3" fill="{c["menu_ink"]}" opacity=".45"/>'
            f'<rect x="868" y="7" width="22" height="10" rx="3" fill="{c["menu_ink"]}" opacity=".45"/>'
            f'<rect x="902" y="8" width="44" height="8" rx="4" fill="{c["menu_ink"]}" opacity=".55"/>')
    return glyph(c) + bars


def menubar_left(c):
    return (f'<rect x="16" y="6" width="12" height="12" rx="3" fill="{c["menu_ink"]}" opacity=".7"/>'
            f'<rect x="42" y="8" width="40" height="8" rx="4" fill="{c["menu_ink"]}" opacity=".6"/>'
            f'<rect x="96" y="8" width="28" height="8" rx="4" fill="{c["menu_ink"]}" opacity=".35"/>'
            f'<rect x="136" y="8" width="34" height="8" rx="4" fill="{c["menu_ink"]}" opacity=".35"/>'
            f'<rect x="182" y="8" width="30" height="8" rx="4" fill="{c["menu_ink"]}" opacity=".35"/>')


def sun(cx, cy, color):
    """SF `sun.max` at 12 pt, roughly: a ring and eight rays."""
    rays = []
    for i in range(8):
        a = i * math.pi / 4
        rays.append(f"M{cx + 4.4 * math.cos(a):.2f},{cy + 4.4 * math.sin(a):.2f} "
                    f"L{cx + 6.0 * math.cos(a):.2f},{cy + 6.0 * math.sin(a):.2f}")
    return (f'<circle cx="{cx}" cy="{cy}" r="2.5" fill="none" stroke="{color}" stroke-width="1.3"/>'
            f'<path d="{" ".join(rays)}" stroke="{color}" stroke-width="1.3" stroke-linecap="round"/>')


def slider(c):
    x, y, w, h = TRACK
    width = Track(fill_width(LEVEL0))
    width.hold(T_DRAG0)
    for t in SAMPLES[1:]:
        width.add(t, round(fill_width(level_at(t)), 2), LINEAR)
    width.jump(T_RESET, fill_width(LEVEL0))
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{c["track"]}"/>',
           f'<rect x="{x}" y="{y}" width="{fill_width(LEVEL0):.2f}" height="{h}" rx="12" fill="{c["fill"]}" '
           f'stroke="{c["fill_edge"]}" stroke-width="0.5">{width.svg("width")}</rect>',
           sun(x + 12, y + 12, "#111113")]
    # The percent: one text per value the drag passes, each shown while it is current.
    shown = [(0.0, round(LEVEL0 * 100))]
    for t in SAMPLES[1:]:
        p = round(level_at(t) * 100)
        if p != shown[-1][1]:
            shown.append((t, p))
    spans = {}
    for i, (t, p) in enumerate(shown):
        end = shown[i + 1][0] if i + 1 < len(shown) else T_RESET
        spans.setdefault(p, []).append((t, end))
    spans.setdefault(round(LEVEL0 * 100), []).append((T_RESET, T))
    texts = []
    for p, ranges in spans.items():
        changes, start_visible = [], False
        for a, b in sorted(ranges):
            if a <= 0:
                start_visible = True
            else:
                changes.append((a, 1))
            if b < T:
                changes.append((b, 0))
        texts.append(text(percent_x(), y + 16.5, str(p), 13, None, 400, "end", f' opacity="{1 if start_visible else 0}"',
                          anim=discrete("opacity", changes, 1 if start_visible else 0)))
    hot = discrete("fill", [(0.85, c["ink"]), (2.25, c["ink2"])], c["ink2"])
    out.append(f'<g fill="{c["ink2"]}">{hot}{"".join(texts)}</g>')
    return "".join(out)


def chip(c):
    x, y, w, h = CHIP
    wash = discrete("fill", [(T_CHIP, c["wash_pressed"]), (T_PICK + 0.08, c["wash"])], c["wash"])
    chev = f"M{x + w - 19},{y + 10.5} l3.5,3.5 l3.5,-3.5"
    swap = [(T_SWAP1, 1), (T_SWAP2, 0)]
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{c["wash"]}">{wash}</rect>'
            + text(x + 10, y + 16.5, "2560 × 1440", 13, c["ink"], anim=discrete("opacity", [(T_SWAP1, 0), (T_SWAP2, 1)], 1))
            + text(x + 10, y + 16.5, "3008 × 1692", 13, c["ink"], extra=' opacity="0"', anim=discrete("opacity", swap, 0))
            + f'<path d="{chev}" fill="none" stroke="{c["ink2"]}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>')


def panel(c):
    """The panel, one display (DELL U2723QE), v5 geometry; it opens at T_PANEL and closes at T_CLOSE.
    While the change waits for Keep its content is locked at α.5."""
    module = (f'<rect x="{PX + 6}" y="{PY + 6}" width="{PW - 12}" height="108" rx="12" fill="{c["module"]}" '
              f'stroke="{c["module_edge"]}" stroke-width="0.5"/>')
    ell = "".join(f'<circle cx="{PX + PW - 27 + 4.5 * k}" cy="{PY + 28}" r="1.5" fill="{c["ink2"]}"/>' for k in range(3))
    lock = discrete("opacity", [(T_SWAP1, 0.5), (T_SWAP2, 1)], 1)
    content = (f'<g>{lock}'
               + text(CX, PY + 33, "DELL U2723QE", 13, c["ink"], 600) + ell + slider(c) + chip(c) + "</g>")
    footer = (text(CX, PY + 140.5, "Settings…", 13, c["ink2"]) + text(PX + PW - 18, PY + 140.5, "Quit", 13, c["ink2"], anchor="end"))
    shown = Track(0.0).hold(T_PANEL).add(T_PANEL + 0.16, 1.0, OUT).hold(T_CLOSE).add(T_CLOSE + 0.16, 0.0, IN)
    rise = (f'<animateTransform attributeName="transform" type="translate" dur="{T:g}s" repeatCount="indefinite" '
            f'calcMode="spline" keyTimes="0;{T_PANEL / T:.5f};{(T_PANEL + 0.16) / T:.5f};1" values="0 -6;0 -6;0 0;0 0" '
            f'keySplines="{LINEAR};{OUT};{LINEAR}"/>')
    return (f'<g opacity="0">{shown.svg("opacity")}<g>{rise}'
            f'<rect x="{PX}" y="{PY}" width="{PW}" height="{PH}" rx="18" fill="{c["panel"]}" stroke="{c["panel_edge"]}" '
            f'stroke-width="0.5" filter="url(#shadow)"/>'
            + module + content + footer + "</g></g>")


def mode_menu(c):
    """The chip's menu: the recommended sizes, a divider, `Show All…` (Panel/DisplaySection.swift)."""
    x, y, w, h = MENU_POP
    shown = Track(0.0).hold(T_CHIP).add(T_CHIP + 0.06, 1.0, OUT).hold(T_PICK).add(T_PICK + 0.08, 0.0, IN)
    rows = ["3008 × 1692", "2560 × 1440", "1920 × 1080"]
    hl = discrete("opacity", [(2.75, 1), (T_PICK + 0.08, 0)], 0)
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{c["popup"]}" stroke="{c["popup_edge"]}" stroke-width="0.5" filter="url(#shadow)"/>',
           f'<rect x="{x + 5}" y="{ROW0_Y}" width="{w - 10}" height="22" rx="4" fill="{c["highlight"]}" opacity="0">{hl}</rect>']
    for i, r in enumerate(rows):
        out.append(text(x + 25, ROW0_Y + 15.5 + 22 * i, r, 13, c["ink"]))
    cy = ROW0_Y + 22 + 11
    out.append(f'<path d="M{x + 10},{cy} l3,3 l5.5,-6.5" fill="none" stroke="{c["ink"]}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>')
    sep = ROW0_Y + 66 + 5
    out.append(f'<rect x="{x + 10}" y="{sep}" width="{w - 20}" height="1" fill="{c["popup_edge"]}"/>')
    out.append(text(x + 25, sep + 20.5, "Show All…", 13, c["ink"]))
    return f'<g opacity="0">{shown.svg("opacity")}{"".join(out)}</g>'


def keep_card():
    """Overlays/KeepCard.swift in its own 340 × 132 space: title, the Fuse (15 dots, 8 pt, pitch 18),
    Revert and Keep; resolved: `Reverted` and the arrow.uturn.backward symbol."""
    live = [text(170, 42, "Keep 3008 × 1692?", 15, "#FFFFFF", 600, "middle")]
    for i in range(15):
        cx, cy = 44 + 18 * i, 61.5
        out_at = T_FUSE + DOT * (15 - i)            # the rightmost goes out first
        lit = Track(1.0).hold(out_at - DOT).add(out_at, 0.0, OUT).jump(T_CLOSE, 1.0)
        live.append(f'<circle cx="{cx}" cy="{cy}" r="3.5" fill="none" stroke="{SPENT}" stroke-width="1"/>'
                    f'<circle cx="{cx}" cy="{cy}" r="4" fill="{SIGNAL}">{lit.svg("opacity")}</circle>')
    live.append(f'<rect x="68" y="77.5" width="96" height="28" rx="8" fill="#FFFFFF" fill-opacity=".17"/>'
                + text(116, 96, "Revert", 14, "#FFFFFF", 500, "middle")
                + '<rect x="176" y="77.5" width="96" height="28" rx="8" fill="#FFFFFF"/>'
                + text(224, 96, "Keep", 14, "#111113", 600, "middle"))
    resolved = (text(170, 55.5, "Reverted", 15, "#FFFFFF", 600, "middle")
                + '<path d="M164,73 l-5,5 l5,5 M159.5,78 H175 a6.5,6.5 0 0 1 0,13 H168" fill="none" stroke="#FFFFFF" '
                  'stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>')
    swap = [(T_SWAP2, 0), (T_CLOSE, 1)]
    plate = (f'<rect x="0.5" y="0.5" width="339" height="131" rx="20" fill="{PLATE}" fill-opacity=".97" '
             f'stroke="{PLATE_EDGE}"/>')
    body = (plate + f'<g>{discrete("opacity", swap, 1)}{"".join(live)}</g>'
            + f'<g opacity="0">{discrete("opacity", [(T_SWAP2, 1), (T_CLOSE, 0)], 0)}{resolved}</g>')
    shown = Track(0.0).hold(T_CARD).add(T_CARD + 0.18, 1.0, OUT).hold(T_CARD_OUT).add(T_CARD_OUT + 0.16, 0.0, IN)
    grow = (f'<animateTransform attributeName="transform" type="scale" dur="{T:g}s" repeatCount="indefinite" '
            f'calcMode="spline" keyTimes="0;{T_CARD / T:.5f};{(T_CARD + 0.18) / T:.5f};1" values="0.96;0.96;1;1" '
            f'keySplines="{LINEAR};{OUT};{LINEAR}"/>')
    ccx, ccy = CARD_X + CARD_W / 2, CARD_Y + CARD_H / 2
    return (f'<g opacity="0" filter="url(#shadow)">{shown.svg("opacity")}'
            f'<g transform="translate({fmt(ccx)} {fmt(ccy)})"><g>{grow}'
            f'<g transform="translate({fmt(-CARD_W / 2)} {fmt(-CARD_H / 2)}) scale({CARD_K})">{body}</g></g></g></g>')


def cursor(c):
    """macOS arrow: to the glyph, to the slider's end, drags it to 0, to the chip, picks 3008 × 1692,
    then fades; it comes back at its start for the next loop."""
    start = (520.0, 330.0)
    glyph_pt = (GLYPH_X + 9.0, 13.0)
    grab_y = TRACK[1] + 12
    pos = Track(start).hold(0.05).add(0.35, glyph_pt, OUT).hold(0.60)
    pos.add(0.85, (round(TRACK[0] + fill_width(LEVEL0) - 4, 2), grab_y), OUT).hold(T_DRAG0)
    for t in SAMPLES[1:]:
        pos.add(t, (round(TRACK[0] + fill_width(level_at(t)) - 4, 2), grab_y), LINEAR)
    pos.hold(2.20).add(2.45, (CHIP[0] + 50.0, CHIP[1] + 13.0), OUT).hold(2.60)
    pos.add(2.80, (CHIP[0] + 54.0, ROW0_Y + 12.0), OUT).hold(3.30).jump(3.30, start)
    seen = Track(1.0).hold(3.00).add(3.25, 0.0, IN).hold(7.05).add(7.35, 1.0, OUT)
    arrow = "M0,0 L0,17 L4.3,13 L7.2,19.6 L10,18.4 L7.2,12 L12.8,12 Z"
    return (f'<g>{pos.svg("translate", "animateTransform")}{seen.svg("opacity")}'
            f'<path d="{arrow}" fill="#111113" stroke="#FFFFFF" stroke-width="1.2" stroke-linejoin="round"/></g>')


def blank():
    """A mode change blanks the screen for a moment (shortened here)."""
    tr = Track(0.0)
    for mid in (T_SWAP1, T_SWAP2):
        tr.hold(mid - 0.12).add(mid, 1.0, IN).add(mid + 0.16, 0.0, OUT)
    return f'<rect width="{W}" height="{H}" fill="#000" opacity="0">{tr.svg("opacity")}</rect>'


def dimming(c):
    """The monitor's light: the drag dims everything on it (the backlight, then the gamma table);
    the loop brings it back up after the panel has closed."""
    dim_max = float(c["dim"])
    tr = Track(0.0).hold(T_DRAG0)
    for t in SAMPLES[1:]:
        tr.add(t, round(dim_of(level_at(t), dim_max), 4), LINEAR)
    tr.hold(T_CLOSE + 0.1).add(7.2, 0.0, HAND)
    return f'<rect width="{W}" height="{H}" fill="#000" opacity="0">{tr.svg("opacity")}</rect>'


def caption(c, s, t0, t1):
    width = 26 + 7.4 * len(s)
    x, y = (W - width) / 2, H - 58
    return (f'<g opacity="0">{fade([(t0, t1)], ramp=0.2).svg("opacity")}'
            f'<rect x="{x:.1f}" y="{y}" width="{width:.1f}" height="34" rx="17" fill="{c["caption"]}" '
            f'fill-opacity="{c["caption_op"]}" stroke="{c["caption_edge"]}" stroke-width="0.5"/>'
            + text(W / 2, y + 22, s, 15, c["caption_ink"], 500, "middle") + "</g>")


def scene(theme):
    c = THEMES[theme]
    left = (window(c, 40, 56, 500, 318) + window(c, 200, 214, 420, 262, (0.5, 0.66, 0.4, 0.58)) + menubar_left(c))
    right = menubar_right(c) + panel(c) + mode_menu(c)
    body = [
        wallpaper(c),
        scaled(0, 0, f'<rect width="{W}" height="{MENU}" fill="{c["menu"]}" opacity="{c["menu_op"]}"/>', sx=False),
        scaled(0, 0, left),
        scaled(W, 0, right),
        keep_card(),
        cursor(c),
        blank(),
        dimming(c),
        caption(c, "Below the monitor’s own minimum", T_CROSS - 0.1, 2.95),
        caption(c, "Unless you press Keep, changes go back.", T_CARD + 0.05, T_CARD_OUT + 0.1),
    ]
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">
<title id="t">Keeplight: brightness and resolution for every display</title>
<desc id="d">Keeplight's panel opens from the menu bar. Its brightness slider is dragged from 72 to 0 and the monitor dims, below its own minimum. Then 3008 by 1692 is picked as the resolution: the Keep card asks whether to keep it, its fifteen red dots go out one by one, and the resolution goes back.</desc>
<!-- Generated by tools/readme/hero.py — edit the script, not this file. -->
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c["bg0"]}"/><stop offset="1" stop-color="{c["bg1"]}"/></linearGradient>
  <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{c["glow"]}" stop-opacity="{c["glow_op"]}"/><stop offset="1" stop-color="{c["glow"]}" stop-opacity="0"/></radialGradient>
  <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="6" stdDeviation="9" flood-color="#000" flood-opacity="{c["shadow"]}"/></filter>
  <clipPath id="screen"><rect width="{W}" height="{H}" rx="18"/></clipPath>
</defs>
<g clip-path="url(#screen)">
{chr(10).join("  " + b for b in body)}
</g>
</svg>
"""


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out = os.path.join(root, "docs", "images")
    os.makedirs(out, exist_ok=True)
    for theme in THEMES:
        path = os.path.join(out, f"hero-{theme}.svg")
        with open(path, "w", encoding="utf-8") as f:
            f.write(scene(theme))
        print(f"wrote {os.path.relpath(path, root)} ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    main()
