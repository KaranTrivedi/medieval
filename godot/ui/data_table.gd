# data_table.gd
# Reusable, sortable, column-aligned table Control. Build once with
# `set_columns(...)`, push rows with `set_rows(...)`. Header clicks toggle the
# sort column / order; row clicks emit `row_clicked(row_dict)` so the parent
# can navigate (e.g. open a sub-region's panel).
#
# Columns are described as:
#   {
#     "key": String,                # dict key to read from each row
#     "label": String,              # header text
#     "align": "left"|"right"|"center"  (default "left")
#     "format": "int"|"int_thousands"|"text"|"icon_text"  (default "text")
#     "icon": Texture2D (optional)  # rendered before the cell text
#     "width": int (optional)       # min width hint in px
#   }
#
# Why a Control instead of a Tree node: Godot 4's Tree has very limited
# styling control (no per-cell font colour overrides for plain text), and the
# project's medieval look wants careful typography. A grid of Labels gives us
# everything for ~100 rows comfortably.

extends VBoxContainer

const UITheme := preload("res://ui/ui_theme.gd")

signal row_clicked(row: Dictionary)

var _columns: Array = []
var _rows: Array = []
var _sort_key: String = ""
# 1 = ascending, -1 = descending. New sort columns default to DESCENDING because
# "biggest first" is the answer the player usually wants (most income, oldest,
# largest garrison, highest opinion). Re-clicking the same column toggles.
var _sort_dir: int = -1

var _header_row: HBoxContainer
var _body: VBoxContainer


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	# Build the header + body containers programmatically so callers can
	# just `add_child(DataTable.new())` without authoring a scene file.
	var header_wrap := PanelContainer.new()
	header_wrap.add_theme_stylebox_override("panel", UITheme.table_header_stylebox())
	add_child(header_wrap)
	_header_row = HBoxContainer.new()
	_header_row.add_theme_constant_override("separation", 0)
	header_wrap.add_child(_header_row)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 0)
	add_child(_body)
	# If callers configured columns/rows before _ready ran, render now.
	if not _columns.is_empty():
		_rebuild_header()
	if not _rows.is_empty():
		_rebuild_body()


# Set the column schema. Triggers a full rebuild.
func set_columns(cols: Array) -> void:
	_columns = cols.duplicate(true)
	if not _columns.is_empty() and _sort_key == "":
		_sort_key = str(_columns[0].get("key", ""))
	_rebuild_header()
	_rebuild_body()


# Replace all rows. Each row is a flat Dictionary keyed by the columns' `key`s.
func set_rows(rows: Array) -> void:
	_rows = rows.duplicate(true)
	_rebuild_body()


# ── INTERNAL BUILDERS ────────────────────────────────────────────────────────

func _rebuild_header() -> void:
	if _header_row == null:
		return
	for child in _header_row.get_children():
		child.queue_free()
	_header_row.add_theme_stylebox_override("panel", UITheme.table_header_stylebox())
	_header_row.add_theme_constant_override("separation", 0)
	for col in _columns:
		var btn := Button.new()
		btn.flat = true
		btn.text = _header_text(col)
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", UITheme.COL_ACCENT_GOLD)
		btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
		btn.alignment = _h_align(col) as HorizontalAlignment
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size.x = int(col.get("width", 60))
		var key: String = str(col.get("key", ""))
		btn.pressed.connect(func(): _on_header_clicked(key))
		_header_row.add_child(btn)


func _header_text(col: Dictionary) -> String:
	var label: String = str(col.get("label", str(col.get("key", "?"))))
	if str(col.get("key", "")) == _sort_key:
		label += "  ▲" if _sort_dir > 0 else "  ▼"
	return label


func _rebuild_body() -> void:
	if _body == null:
		return
	for child in _body.get_children():
		child.queue_free()
	var sorted_rows: Array = _sorted_rows()
	for i in range(sorted_rows.size()):
		var row: Dictionary = sorted_rows[i]
		var bar := PanelContainer.new()
		bar.add_theme_stylebox_override("panel", UITheme.table_row_stylebox(i % 2 == 1))
		_body.add_child(bar)
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 0)
		hbox.mouse_filter = Control.MOUSE_FILTER_PASS
		bar.add_child(hbox)
		# Make the whole row clickable by overlaying a transparent button.
		var clickable := Button.new()
		clickable.flat = true
		clickable.focus_mode = Control.FOCUS_NONE
		clickable.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		clickable.size_flags_vertical = Control.SIZE_EXPAND_FILL
		clickable.pressed.connect(func(): row_clicked.emit(row))
		for col in _columns:
			var cell := _make_cell(col, row)
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cell.custom_minimum_size.x = int(col.get("width", 60))
			hbox.add_child(cell)
		# Place the clickable AFTER cells so it captures the row.
		# We use mouse_filter STOP on it but PASS on labels for hover effect.
		# Simpler: rely on Godot's stop-on-button mouse filter; cells are
		# Labels so they pass through to the underlying button.
		bar.gui_input.connect(func(ev): _on_row_gui(ev, row))


func _make_cell(col: Dictionary, row: Dictionary) -> Control:
	var fmt: String = str(col.get("format", "text"))
	var key: String = str(col.get("key", ""))
	var raw = row.get(key, "")
	var text: String = _format(raw, fmt)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", UITheme.COL_INK)
	match _h_align(col):
		HORIZONTAL_ALIGNMENT_RIGHT:  l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		HORIZONTAL_ALIGNMENT_CENTER: l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_: l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	# Optional icon: render via a leading character if no Texture2D given.
	# (Project doesn't ship icon textures yet — we use unicode glyphs.)
	if "icon" in col and col["icon"] != null:
		var glyph := str(col["icon"])
		l.text = glyph + "  " + text
	return l


func _h_align(col: Dictionary) -> int:
	match str(col.get("align", "left")):
		"right":  return HORIZONTAL_ALIGNMENT_RIGHT
		"center": return HORIZONTAL_ALIGNMENT_CENTER
	return HORIZONTAL_ALIGNMENT_LEFT


# Convert a raw value to its display string per the column's `format`.
func _format(raw, fmt: String) -> String:
	match fmt:
		"int":           return str(int(raw)) if raw != null else "—"
		"int_thousands": return _fmt_thousands(int(raw)) if raw != null else "—"
	if raw == null:
		return "—"
	return str(raw)


func _fmt_thousands(n: int) -> String:
	var s := str(n)
	var sign_prefix := ""
	if s.begins_with("-"):
		sign_prefix = "-"
		s = s.substr(1)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count == 3 and i > 0:
			out = "," + out
			count = 0
	return sign_prefix + out


func _sorted_rows() -> Array:
	if _sort_key == "" or _rows.is_empty():
		return _rows
	var rows := _rows.duplicate()
	var key := _sort_key
	var dir := _sort_dir
	rows.sort_custom(func(a, b): return _cmp(a.get(key), b.get(key)) * dir < 0)
	return rows


func _cmp(a, b) -> int:
	# Order: nulls last; numbers numerically; strings lexicographically.
	if a == null and b == null: return 0
	if a == null: return 1
	if b == null: return -1
	if (a is int or a is float) and (b is int or b is float):
		if a < b: return -1
		if a > b: return 1
		return 0
	var sa := str(a).to_lower()
	var sb := str(b).to_lower()
	if sa < sb: return -1
	if sa > sb: return 1
	return 0


func _on_header_clicked(key: String) -> void:
	# Toggle direction on the same column; switching columns resets to DESC
	# (largest-first), which is the answer players usually want for the
	# numeric columns that dominate these tables.
	if key == _sort_key:
		_sort_dir = -_sort_dir
	else:
		_sort_key = key
		_sort_dir = -1
	_rebuild_header()
	_rebuild_body()


func _on_row_gui(ev: InputEvent, row: Dictionary) -> void:
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
		if (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			row_clicked.emit(row)
