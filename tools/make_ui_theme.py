"""12.5: дизайн-система интерфейса -> resources/ui_theme.tres (тема всего проекта, gui/theme/custom).
Палитра и модуль отступов U = 8 px здесь, в одном месте; тему править этим скриптом, а не руками:
    python tools/make_ui_theme.py resources/ui_theme.tres
Вариации: PrimaryButton (золотая, главное действие), DangerButton (необратимое), TabButton, ListRow,
IconButton; панели InsetPanel, SectionPanel, HudPanel, TrackerPanel; надписи TitleLabel, SubtitleLabel,
CaptionLabel, SectionLabel, AccentLabel, HintLabel, KeyLabel (клавиша в рамке)."""
import sys
# Палитра
BG_PANEL = (0.05, 0.08, 0.13, 0.9)
SURF = (0.15, 0.19, 0.27, 0.96)
SURF_HI = (0.21, 0.26, 0.36, 0.98)
SURF_LO = (0.10, 0.13, 0.19, 1)
SURF_OFF = (0.12, 0.15, 0.21, 0.6)
INSET = (0.03, 0.05, 0.09, 0.7)
BORDER = (0.30, 0.35, 0.45, 1)
TEXT = (0.93, 0.93, 0.9, 1)
MUTED = (0.78, 0.8, 0.84, 1)
FAINT = (1, 1, 1, 0.5)
OFF = (1, 1, 1, 0.32)
GOLD = (0.86, 0.7, 0.38, 1)
GOLD_HI = (0.95, 0.8, 0.5, 1)
GOLD_LO = (0.72, 0.56, 0.28, 1)
GOLD_OFF = (0.86, 0.7, 0.38, 0.3)
GOLD_TINT = (0.86, 0.7, 0.38, 0.16)
INK = (0.1, 0.08, 0.05, 1)
DANGER = (0.6, 0.21, 0.19, 1)
DANGER_HI = (0.74, 0.28, 0.25, 1)
DANGER_LO = (0.48, 0.16, 0.14, 1)
DANGER_OFF = (0.6, 0.21, 0.19, 0.3)
DANGER_TEXT = (1, 0.94, 0.92, 1)
U = 8  # модуль отступов

subs = []
def c(col):
    return "Color(%s)" % ", ".join(("%g" % v) for v in col)

def box(name, bg=None, border=None, bw=0, radius=U, margin=(2*U, U), expand=0, draw_center=True, extra=None):
    lines = ['[sub_resource type="StyleBoxFlat" id="%s"]' % name]
    mh, mv = margin[0], margin[1]
    if len(margin) == 4:
        l, t, r, b = margin
    else:
        l, t, r, b = mh, mv, mh, mv
    for k, v in (("left", l), ("top", t), ("right", r), ("bottom", b)):
        lines.append("content_margin_%s = %.1f" % (k, v))
    if bg is not None:
        lines.append("bg_color = " + c(bg))
    if not draw_center:
        lines.append("draw_center = false")
    if bw:
        for side in ("left", "top", "right", "bottom"):
            w = bw if isinstance(bw, int) else bw.get(side, 0)
            if w:
                lines.append("border_width_%s = %d" % (side, w))
        lines.append("border_color = " + c(border))
    for k in ("top_left", "top_right", "bottom_right", "bottom_left"):
        if radius:
            lines.append("corner_radius_%s = %d" % (k, radius))
    if expand:
        for side in ("left", "top", "right", "bottom"):
            e = expand if isinstance(expand, (int, float)) else expand.get(side, 0)
            if e:
                lines.append("expand_margin_%s = %.1f" % (side, e))
    for k, v in (extra or {}).items():
        lines.append("%s = %s" % (k, v))
    subs.append("\n".join(lines))
    return 'SubResource("%s")' % name


props = {}
def put(k, v):
    props[k] = v

# ---- кнопки ----
focus = box("focus", border=GOLD_HI, bw=2, radius=U + 2, draw_center=False, expand=2)

def button_type(t, normal, hover, pressed, disabled, fg, fg_off, fg_pressed=None, hover_pressed=None):
    put(t + "/styles/normal", normal)
    put(t + "/styles/hover", hover)
    put(t + "/styles/pressed", pressed)
    put(t + "/styles/hover_pressed", hover_pressed or pressed)
    put(t + "/styles/disabled", disabled)
    put(t + "/styles/focus", focus)
    fp = fg_pressed or fg
    for state, col in (("font_color", fg), ("font_hover_color", fg), ("font_focus_color", fg),
                       ("font_pressed_color", fp), ("font_hover_pressed_color", fp), ("font_disabled_color", fg_off)):
        put(t + "/colors/" + state, c(col))
    for state, col in (("icon_normal_color", fg), ("icon_hover_color", fg), ("icon_focus_color", fg),
                       ("icon_pressed_color", fp), ("icon_hover_pressed_color", fp), ("icon_disabled_color", fg_off)):
        put(t + "/colors/" + state, c(col))

btn = dict(normal=box("btn_normal", SURF, BORDER, 1), hover=box("btn_hover", SURF_HI, GOLD_OFF, 1),
           pressed=box("btn_pressed", SURF_LO, GOLD, 1), disabled=box("btn_disabled", SURF_OFF, (0.3, 0.35, 0.45, 0.4), 1))
button_type("Button", btn["normal"], btn["hover"], btn["pressed"], btn["disabled"], TEXT, OFF, GOLD_HI)
put("Button/constants/h_separation", U)
put("Button/constants/icon_max_width", 3 * U)
button_type("OptionButton", btn["normal"], btn["hover"], btn["pressed"], btn["disabled"], TEXT, OFF)
put("OptionButton/constants/h_separation", U)
put("OptionButton/constants/arrow_margin", 2 * U)

# золотая главная кнопка
put("PrimaryButton/base_type", '&"Button"')
button_type("PrimaryButton", box("pri_normal", GOLD), box("pri_hover", GOLD_HI), box("pri_pressed", GOLD_LO),
            box("pri_disabled", GOLD_OFF), INK, (0.1, 0.08, 0.05, 0.55))
# тревожная: необратимое (выход, отказ)
put("DangerButton/base_type", '&"Button"')
button_type("DangerButton", box("dng_normal", DANGER), box("dng_hover", DANGER_HI), box("dng_pressed", DANGER_LO),
            box("dng_disabled", DANGER_OFF), DANGER_TEXT, (1, 0.94, 0.92, 0.45))
# вкладка: выбранная — золотой подписью и чертой снизу
put("TabButton/base_type", '&"Button"')
button_type("TabButton", box("tab_normal", (1, 1, 1, 0.04)), box("tab_hover", SURF_HI),
            box("tab_pressed", GOLD_TINT, GOLD, {"bottom": 2}), box("tab_disabled", (1, 1, 1, 0.02)),
            (1, 1, 1, 0.6), OFF, GOLD_HI)
# строка списка (мир в меню): выбранная — золотая рамка
put("ListRow/base_type", '&"Button"')
row_sel = box("row_selected", GOLD_TINT, (0.86, 0.7, 0.38, 0.9), 2, radius=6)
button_type("ListRow", box("row_normal", (1, 1, 1, 0.04), radius=6), box("row_hover", SURF_HI, radius=6),
            row_sel, box("row_disabled", (1, 1, 1, 0.02), radius=6), TEXT, OFF, hover_pressed=row_sel)
# пиктограмма без подложки (звёздочка); фон только под мышью
put("IconButton/base_type", '&"Button"')
button_type("IconButton", box("ico_normal", None, radius=6, margin=(U, U), draw_center=False),
            box("ico_hover", (1, 1, 1, 0.08), radius=6, margin=(U, U)),
            box("ico_pressed", (1, 1, 1, 0.14), radius=6, margin=(U, U)),
            box("ico_disabled", None, radius=6, margin=(U, U), draw_center=False), GOLD, OFF, GOLD_HI)

# флажок
chk_hover = box("chk_hover", (1, 1, 1, 0.06), radius=6, margin=(U, U // 2))
chk = box("chk_normal", None, radius=6, margin=(U, U // 2), draw_center=False)
for s, v in (("normal", chk), ("hover", chk_hover), ("pressed", chk), ("hover_pressed", chk_hover), ("disabled", chk), ("focus", focus)):
    put("CheckBox/styles/" + s, v)
for s, v in (("font_color", MUTED), ("font_hover_color", TEXT), ("font_focus_color", TEXT), ("font_pressed_color", TEXT),
             ("font_hover_pressed_color", TEXT), ("font_disabled_color", OFF)):
    put("CheckBox/colors/" + s, c(v))
put("CheckBox/constants/h_separation", U)

# ---- поля, полосы, ползунки ----
put("LineEdit/styles/normal", box("edit_normal", SURF_LO, BORDER, 1, margin=(U + 4, U)))
put("LineEdit/styles/focus", box("edit_focus", None, GOLD, 2, radius=U, draw_center=False))
put("LineEdit/styles/read_only", box("edit_ro", SURF_OFF, margin=(U + 4, U)))
put("LineEdit/colors/font_color", c(TEXT))
put("LineEdit/colors/font_placeholder_color", c(FAINT))
put("LineEdit/colors/caret_color", c(GOLD_HI))
put("LineEdit/colors/selection_color", c((0.86, 0.7, 0.38, 0.35)))
put("ProgressBar/styles/background", box("bar_bg", SURF_LO, radius=U // 2, margin=(0, 0)))
put("ProgressBar/styles/fill", box("bar_fill", GOLD, radius=U // 2, margin=(0, 0)))
put("ProgressBar/colors/font_color", c(TEXT))
put("HSlider/styles/slider", box("slider", SURF_LO, radius=3, margin=(0, 3)))
put("HSlider/styles/grabber_area", box("slider_fill", GOLD_LO, radius=3, margin=(0, 3)))
put("HSlider/styles/grabber_area_highlight", box("slider_fill_hi", GOLD, radius=3, margin=(0, 3)))
for t in ("VScrollBar", "HScrollBar"):
    put(t + "/styles/scroll", box("scroll_" + t, (1, 1, 1, 0.04), radius=4, margin=(2, 2)))
    put(t + "/styles/grabber", box("grab_" + t, (1, 1, 1, 0.22), radius=4, margin=(2, 2)))
    put(t + "/styles/grabber_highlight", box("grab_hi_" + t, (1, 1, 1, 0.35), radius=4, margin=(2, 2)))
    put(t + "/styles/grabber_pressed", box("grab_pr_" + t, GOLD_LO, radius=4, margin=(2, 2)))
subs.append('[sub_resource type="StyleBoxLine" id="sep"]\ncolor = Color(1, 1, 1, 0.1)\nthickness = 1')
put("HSeparator/styles/separator", 'SubResource("sep")')
put("HSeparator/constants/separation", 2 * U)

# ---- вкладки (настройки) ----
put("TabContainer/styles/panel", box("tabs_panel", (1, 1, 1, 0.03), radius=U, margin=(2 * U, 2 * U)))
put("TabContainer/styles/tab_selected", box("tabs_sel", GOLD_TINT, GOLD, {"bottom": 2}, radius=6, margin=(2 * U, U)))
put("TabContainer/styles/tab_unselected", box("tabs_unsel", (1, 1, 1, 0.04), radius=6, margin=(2 * U, U)))
put("TabContainer/styles/tab_hovered", box("tabs_hov", SURF_HI, radius=6, margin=(2 * U, U)))
put("TabContainer/styles/tab_disabled", box("tabs_off", (1, 1, 1, 0.02), radius=6, margin=(2 * U, U)))
put("TabContainer/styles/tab_focus", focus)
put("TabContainer/colors/font_selected_color", c(GOLD_HI))
put("TabContainer/colors/font_unselected_color", c((1, 1, 1, 0.6)))
put("TabContainer/colors/font_hovered_color", c(TEXT))
put("TabContainer/constants/side_margin", 0)
put("TabBar/constants/h_separation", U // 2)

# ---- всплывающие окна: меню выбора, подсказки, диалоги ----
popup = box("popup", SURF_LO, BORDER, 1, margin=(U, U))
put("PopupMenu/styles/panel", popup)
put("PopupMenu/styles/hover", box("popup_hover", SURF_HI, radius=6, margin=(U, U // 2)))
put("PopupMenu/colors/font_color", c(MUTED))
put("PopupMenu/colors/font_hover_color", c(TEXT))
put("PopupMenu/constants/v_separation", U)
put("TooltipPanel/styles/panel", box("tip", SURF_LO, BORDER, 1, radius=6, margin=(U + 4, U // 2 + 2)))
put("TooltipLabel/colors/font_color", c(TEXT))
put("TooltipLabel/font_sizes/font_size", 14)
put("Window/styles/embedded_border", box("win", (0.07, 0.1, 0.16, 0.98), GOLD_OFF, 1, radius=U + 4, margin=(0, 0),
                                         expand={"left": 2 * U, "top": 5 * U, "right": 2 * U, "bottom": 2 * U}))
put("Window/styles/embedded_unfocused_border", 'SubResource("win")')
put("Window/colors/title_color", c(GOLD_HI))
put("Window/font_sizes/title_font_size", 17)
put("Window/constants/title_height", 5 * U)
put("AcceptDialog/styles/panel", box("dlg", (0.07, 0.1, 0.16, 1), radius=0, margin=(2 * U, 2 * U)))
put("AcceptDialog/constants/buttons_separation", U)
put("AcceptDialog/constants/buttons_min_width", 15 * U)
put("AcceptDialog/constants/buttons_min_height", 5 * U)

# ---- панели ----
put("PanelContainer/styles/panel", box("panel", BG_PANEL, (1, 1, 1, 0.06), 1, radius=2 * U, margin=(3 * U, 3 * U)))
put("InsetPanel/base_type", '&"PanelContainer"')
put("InsetPanel/styles/panel", box("inset", INSET, radius=U, margin=(U // 2, U // 2)))
put("HudPanel/base_type", '&"PanelContainer"')
put("HudPanel/styles/panel", box("hud", (0.04, 0.06, 0.1, 0.7), radius=U, margin=(U + 2, U + 2)))
put("TrackerPanel/base_type", '&"PanelContainer"')
put("TrackerPanel/styles/panel", box("tracker", (0.06, 0.07, 0.06, 0.62), (1, 0.82, 0.32, 0.85), {"left": 3}, radius=4,
                                       margin=(2 * U - 4, U, U, U)))
put("SectionPanel/base_type", '&"PanelContainer"')
put("SectionPanel/styles/panel", box("section", (1, 1, 1, 0.04), radius=U, margin=(2 * U, U + 4)))

# ---- отступы контейнеров: шаг 8 ----
put("BoxContainer/constants/separation", U)
put("VBoxContainer/constants/separation", U)
put("HBoxContainer/constants/separation", U)
put("GridContainer/constants/h_separation", U)
put("GridContainer/constants/v_separation", U)
put("FlowContainer/constants/h_separation", U)
put("FlowContainer/constants/v_separation", U)

# ---- надписи ----
put("Label/colors/font_color", c(TEXT))
put("TitleLabel/base_type", '&"Label"')
put("TitleLabel/colors/font_color", c(GOLD))
put("TitleLabel/font_sizes/font_size", 34)
put("SubtitleLabel/base_type", '&"Label"')
put("SubtitleLabel/colors/font_color", c(MUTED))
put("SubtitleLabel/font_sizes/font_size", 15)
put("CaptionLabel/base_type", '&"Label"')
put("CaptionLabel/colors/font_color", c(FAINT))
put("CaptionLabel/font_sizes/font_size", 13)
put("SectionLabel/base_type", '&"Label"')
put("SectionLabel/colors/font_color", c((0.86, 0.7, 0.38, 0.85)))
put("SectionLabel/font_sizes/font_size", 13)
put("AccentLabel/base_type", '&"Label"')
put("AccentLabel/colors/font_color", c((0.85, 0.72, 0.42, 0.9)))
put("AccentLabel/font_sizes/font_size", 14)
# клавиша в подсказках управления: рамка вокруг названия
put("KeyLabel/base_type", '&"Label"')
put("KeyLabel/colors/font_color", c(TEXT))
put("KeyLabel/font_sizes/font_size", 12)
put("KeyLabel/styles/normal", box("key", (1, 1, 1, 0.06), (1, 1, 1, 0.22), 1, radius=4, margin=(U - 2, 1)))
put("HintLabel/base_type", '&"Label"')
put("HintLabel/colors/font_color", c(MUTED))
put("HintLabel/font_sizes/font_size", 13)

out = ['[gd_resource type="Theme" load_steps=%d format=3]' % (len(subs) + 1), ""]
for s in subs:
    out += [s, ""]
out.append("[resource]")
out.append("default_font_size = 18")
for k in sorted(props):
    v = props[k]
    out.append("%s = %s" % (k, v))
open(sys.argv[1], "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
print(len(subs), len(props))
