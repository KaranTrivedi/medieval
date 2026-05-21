# family_tree_panel.gd
# A wide centred Panel that lays out three generations around the focal
# character: parents on top, holder + spouse + siblings in the middle,
# children on the bottom. Each person is a clickable box that refocuses
# the tree on them (so you can walk the dynasty).
#
# Built programmatically — pass `show_for(character_id)` to populate.

extends Panel

# UITheme is autoloaded as a global class via `class_name UITheme` in ui_theme.gd.

signal closed
signal navigate_to(character_id: int)     # alias of clicking the centre name

var _root: VBoxContainer
var _focus_id: int = 0


func _ready() -> void:
	custom_minimum_size = Vector2(880, 640)
	mouse_filter = Control.MOUSE_FILTER_STOP
	UITheme.style_panel(self)

	_root = VBoxContainer.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.offset_left = 16
	_root.offset_top = 14
	_root.offset_right = -16
	_root.offset_bottom = -14
	_root.add_theme_constant_override("separation", 12)
	add_child(_root)
	visible = false


# Esc closes the panel when it's the active prompt.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			accept_event()


func show_for(character_id: int) -> void:
	_focus_id = character_id
	_rebuild()
	visible = true
	var p := get_parent()
	if p != null:
		p.move_child(self, p.get_child_count() - 1)


func close() -> void:
	visible = false
	closed.emit()


func _rebuild() -> void:
	for c in _root.get_children():
		c.queue_free()

	# Header bar.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	_root.add_child(top)
	var header := Label.new()
	header.text = "FAMILY TREE"
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color(0.85, 0.78, 0.55))
	top.add_child(header)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	var close_btn := UITheme.styled_button("✕")
	close_btn.tooltip_text = "Close (Esc)"
	close_btn.pressed.connect(close)
	top.add_child(close_btn)
	_root.add_child(HSeparator.new())

	if _focus_id <= 0:
		_root.add_child(_text_label("No character selected.", 16))
		return

	var focus: Dictionary = GameState.character(_focus_id)
	if focus.is_empty():
		_root.add_child(_text_label("Character #%d not found." % _focus_id, 16))
		return

	# Pull relations once.
	var rels: Array = GameState.relations_of(_focus_id)
	var parents: Array = _filter(rels, "parent")
	var spouses: Array = _filter(rels, "spouse")
	var siblings: Array = _filter(rels, "sibling")
	var children: Array = _filter(rels, "child")

	# ROW 1 — Family + Siblings as TWO separate framed groups, side by side
	# (mirrors the Shogun 2 family screen the user referenced). Parents +
	# spouse sit in the Family box on the left; brothers/sisters in a
	# smaller Siblings box on the right.
	var top_groups := HBoxContainer.new()
	top_groups.add_theme_constant_override("separation", 18)
	top_groups.alignment = BoxContainer.ALIGNMENT_CENTER
	_root.add_child(top_groups)
	top_groups.add_child(_framed_group("FAMILY", parents.map(func(r): return r.other),
			"(no recorded parents)", false))
	top_groups.add_child(_framed_group("SIBLINGS", siblings.map(func(r): return r.other),
			"(none recorded)", true))

	# Connector down to the central head-of-house row.
	_root.add_child(_v_arrow())

	# ROW 2 — house head + spouse, centred.
	var couple_col := VBoxContainer.new()
	couple_col.add_theme_constant_override("separation", 4)
	couple_col.alignment = BoxContainer.ALIGNMENT_CENTER
	couple_col.add_child(_caption("HOUSE HEAD"))
	var couple_row := HBoxContainer.new()
	couple_row.add_theme_constant_override("separation", 12)
	couple_row.alignment = BoxContainer.ALIGNMENT_CENTER
	couple_row.add_child(_chip(focus, true))
	if not spouses.is_empty():
		var heart := Label.new()
		heart.text = "⚭"
		heart.add_theme_font_size_override("font_size", 18)
		heart.add_theme_color_override("font_color", Color(0.85, 0.55, 0.40))
		heart.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		couple_row.add_child(heart)
		couple_row.add_child(_chip(spouses[0].other, false))
	couple_col.add_child(couple_row)
	_root.add_child(couple_col)

	# Connector to children.
	_root.add_child(_v_arrow())

	# ROW 3 — children, framed.
	_root.add_child(_framed_group("CHILDREN", children.map(func(r): return r.other),
			"(no recorded children)", false))


# A boxed group of chips with a captioned border (parchment styled). Used for
# the FAMILY / SIBLINGS / CHILDREN groupings — gives each grouping its own
# visual frame instead of bleeding rows into one another.
#
# Args:
#   caption (String): heading label, drawn above the box in small caps.
#   persons (Array): list of other-character dicts to chip.
#   empty_text (String): shown when persons is empty.
#   small (bool): when true, chips render at compact (~70%) scale — used for
#       the SIBLINGS group so the head-of-house row stays the visual anchor.
# Returns:
#   PanelContainer (with the caption above as a sibling — wrapped in a VBox).
func _framed_group(caption: String, persons: Array, empty_text: String, small: bool) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(_caption(caption))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.chip_stylebox(false))
	col.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(row)
	if persons.is_empty():
		var empty := _text_label(empty_text, 11)
		empty.add_theme_color_override("font_color", Color(0.45, 0.40, 0.30))
		row.add_child(empty)
	else:
		for p in persons:
			row.add_child(_chip(p, false, small))
	return col


# ── BUILDERS ─────────────────────────────────────────────────────────────────

func _row_with_caption(caption: String, row: Control) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(_caption(caption))
	col.add_child(row)
	return col


func _row(persons: Array, empty_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	if persons.is_empty():
		var empty := _text_label(empty_text, 11)
		empty.add_theme_color_override("font_color", Color(0.45, 0.40, 0.30))
		row.add_child(empty)
		return row
	for p in persons:
		row.add_child(_chip(p, false))
	return row


# A single character "chip" — surname-colored card with given name + age,
# clickable to refocus the tree on that character. Deceased characters get
# a darker fill, dimmer text, and a "✝" prefix on the name line.
#
# Args:
#   other (Dictionary): character row to render.
#   is_focus (bool): currently-focused character → gold border.
#   small (bool): compact size for sub-groups like siblings (~70% of normal).
func _chip(other: Dictionary, is_focus: bool, small: bool = false) -> Button:
	var btn := Button.new()
	var alive: bool = bool(other.get("alive", true))
	var full: String = (str(other.get("given_name", "")) + " " + str(other.get("surname", ""))).strip_edges()
	var line2: String = "%s · %d" % [str(other.get("title", "Lord")), int(other.get("age", 0))]
	if not alive:
		full = "✝  " + full
		line2 = "deceased · " + line2
	btn.text = full + "\n" + line2
	if small:
		btn.custom_minimum_size = Vector2(120, 48)
		btn.add_theme_font_size_override("font_size", 10)
	else:
		btn.custom_minimum_size = Vector2(170, 60)
		btn.add_theme_font_size_override("font_size", 12)
	var ink: Color = UITheme.COL_INK_DEAD if not alive else (UITheme.COL_ACCENT_GOLD if is_focus else UITheme.COL_INK)
	btn.add_theme_color_override("font_color", ink)
	btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
	# Custom stylebox: focus characters get the warm gold border, deceased
	# characters get a desaturated fill so they read as "past" at a glance.
	var sb := StyleBoxFlat.new()
	if not alive:
		sb.bg_color = Color(0.060, 0.050, 0.040)
		sb.border_color = Color(0.30, 0.27, 0.23)
	elif is_focus:
		sb.bg_color = Color(0.20, 0.16, 0.08)
		sb.border_color = UITheme.COL_ACCENT_GOLD_DIM
	else:
		sb.bg_color = UITheme.COL_PANEL_BG_DEEP
		sb.border_color = UITheme.COL_PANEL_BORDER
	var w: int = 2 if is_focus else 1
	sb.border_width_left = w; sb.border_width_top = w
	sb.border_width_right = w; sb.border_width_bottom = w
	sb.corner_radius_top_left = 3; sb.corner_radius_top_right = 3
	sb.corner_radius_bottom_left = 3; sb.corner_radius_bottom_right = 3
	sb.content_margin_left = 8; sb.content_margin_right = 8
	sb.content_margin_top = 6; sb.content_margin_bottom = 6
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	var cid: int = int(other.get("character_id", 0))
	btn.pressed.connect(func(): _refocus(cid))
	return btn


func _refocus(cid: int) -> void:
	if cid <= 0:
		return
	_focus_id = cid
	_rebuild()
	navigate_to.emit(cid)


func _filter(rels: Array, kind: String) -> Array:
	var out: Array = []
	for r in rels:
		if str(r.kind) == kind:
			out.append(r)
	return out


func _caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", Color(0.55, 0.50, 0.38))
	return l


func _text_label(text: String, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", Color(0.85, 0.80, 0.65))
	return l


func _v_arrow() -> Label:
	var l := Label.new()
	l.text = "│"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color(0.55, 0.45, 0.30))
	return l
