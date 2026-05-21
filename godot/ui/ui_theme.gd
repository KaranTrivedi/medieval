# ui_theme.gd
# Project-wide UI palette + stylebox builders. Lets every panel share a
# consistent look without each script re-declaring the same StyleBoxFlat
# everywhere. Not an autoload — call as `UITheme.something()` after
# `const UITheme := preload("res://ui/ui_theme.gd")` in the caller.
#
# Why a static class rather than a Theme resource: the panels are built
# programmatically with overrides (font sizes, per-Label colors) and the
# theme resource workflow is painful for one-off styling like this.

class_name UITheme
extends RefCounted

# ── PALETTE ──────────────────────────────────────────────────────────────────
# Medieval parchment + ink mood. Slightly warm darks, gold accents.

const COL_PANEL_BG       := Color(0.082, 0.063, 0.043, 0.985)  # base panel fill
const COL_PANEL_BG_DEEP  := Color(0.055, 0.043, 0.028, 1.0)    # deeper / nested
const COL_PANEL_BORDER   := Color(0.40, 0.31, 0.18, 1.0)       # warm brown
const COL_PANEL_BORDER_LIGHT := Color(0.55, 0.43, 0.24, 1.0)
const COL_ACCENT_GOLD    := Color(0.92, 0.76, 0.34, 1.0)
const COL_ACCENT_GOLD_DIM := Color(0.62, 0.51, 0.24, 1.0)
const COL_ACCENT_RED     := Color(0.78, 0.30, 0.25, 1.0)
const COL_INK            := Color(0.95, 0.92, 0.80, 1.0)       # primary text
const COL_INK_DIM        := Color(0.68, 0.62, 0.50, 1.0)       # secondary text
const COL_INK_MUTED      := Color(0.45, 0.40, 0.30, 1.0)       # tertiary text
const COL_INK_DEAD       := Color(0.55, 0.50, 0.50, 1.0)       # deceased characters
const COL_SEPARATOR      := Color(0.30, 0.24, 0.15, 1.0)
const COL_BUTTON_HOVER   := Color(1.0, 0.97, 0.55, 1.0)

# Per-tier signature gold variants.
const COL_TIER_COUNTRY := Color(0.96, 0.78, 0.30)
const COL_TIER_DUCHY   := Color(0.92, 0.65, 0.40)
const COL_TIER_COUNTY  := Color(0.88, 0.78, 0.55)
const COL_TIER_BARONY  := Color(0.75, 0.70, 0.55)


# ── STYLEBOXES ───────────────────────────────────────────────────────────────

# Outer panel stylebox: deep ink fill with a soft warm border + small radius.
# Used by every modal/overlay panel for a consistent silhouette.
static func panel_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL_BG
	sb.border_color = COL_PANEL_BORDER
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0, 2)
	return sb


# Slightly inset stylebox for the "card" rows inside panels (chips, rows).
static func chip_stylebox(highlighted: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL_BG_DEEP if not highlighted else Color(0.20, 0.16, 0.08)
	sb.border_color = COL_PANEL_BORDER_LIGHT if highlighted else COL_PANEL_BORDER
	var w: int = 2 if highlighted else 1
	sb.border_width_left = w
	sb.border_width_top = w
	sb.border_width_right = w
	sb.border_width_bottom = w
	sb.corner_radius_top_left = 3
	sb.corner_radius_top_right = 3
	sb.corner_radius_bottom_left = 3
	sb.corner_radius_bottom_right = 3
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


# Tabbed area uses a near-zero margin panel.
static func tab_panel_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL_BG_DEEP
	sb.border_color = COL_PANEL_BORDER
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


# Flat StyleBox for table header rows.
static func table_header_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.10, 0.06, 1.0)
	sb.border_color = COL_PANEL_BORDER
	sb.border_width_bottom = 1
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


# Table row stylebox (alternating shade).
static func table_row_stylebox(zebra: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.085, 0.066, 0.045, 1.0) if zebra else Color(0.108, 0.085, 0.057, 1.0)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


# ── BUILDERS ─────────────────────────────────────────────────────────────────
# Common Label/Button factories with consistent typography.

static func section_header(text: String) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", COL_ACCENT_GOLD)
	# Letter-spacing isn't a Label property — fake by using a uniform-width
	# small caps feel via colour alone. (True tracking needs RichTextLabel.)
	col.add_child(l)
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", COL_SEPARATOR)
	col.add_child(sep)
	return col


static func text_label(text: String, font_size: int = 12, color: Color = COL_INK) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


static func dim_label(text: String, font_size: int = 11) -> Label:
	return text_label(text, font_size, COL_INK_DIM)


static func styled_button(text: String, flat: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = flat
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", COL_INK)
	b.add_theme_color_override("font_hover_color", COL_BUTTON_HOVER)
	if not flat:
		b.add_theme_stylebox_override("normal", _btn_box(false, false))
		b.add_theme_stylebox_override("hover", _btn_box(true, false))
		b.add_theme_stylebox_override("pressed", _btn_box(false, true))
	return b


static func _btn_box(hover: bool, pressed: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if pressed:
		sb.bg_color = Color(0.20, 0.16, 0.08)
	elif hover:
		sb.bg_color = Color(0.16, 0.13, 0.07)
	else:
		sb.bg_color = Color(0.12, 0.10, 0.05)
	sb.border_color = COL_PANEL_BORDER_LIGHT if hover or pressed else COL_PANEL_BORDER
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 2
	sb.corner_radius_top_right = 2
	sb.corner_radius_bottom_left = 2
	sb.corner_radius_bottom_right = 2
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


# Apply our panel stylebox to a Panel-derived control.
static func style_panel(p: Panel) -> void:
	p.add_theme_stylebox_override("panel", panel_stylebox())
