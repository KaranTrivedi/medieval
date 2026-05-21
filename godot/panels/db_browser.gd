# db_browser.gd
# Modal panel that lists every user table in the working SQLite DB and shows
# the rows of the table the user picks. Read-only — for inspecting state
# during development. Open via the "DB Browser" button in the Settings panel.
#
# Built procedurally on _ready() so adding/removing columns is purely a
# matter of editing the SELECT statement, no .tscn editing required.

extends Panel

# Max rows we'll pull at once. The full counties_state table is only 55 rows
# but a future chronicle table could be huge; capping keeps the viewer snappy.
const ROW_LIMIT := 500

var _tables: ItemList
var _grid: Tree
var _status: Label
# Cached state for sorting: column index + ascending flag. -1 = unsorted.
var _sort_col: int = -1
var _sort_asc: bool = true
# Last loaded table — needed so a sort click can re-pull and re-render
# without losing track of which table we were on.
var _current_table: String = ""
# Cached column names + rows for the current table, so sort doesn't re-hit
# SQLite for what's already in memory.
var _current_cols: Array = []
var _current_rows: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	var outer := VBoxContainer.new()
	outer.anchor_right = 1.0
	outer.anchor_bottom = 1.0
	outer.offset_left = 12
	outer.offset_top = 12
	outer.offset_right = -12
	outer.offset_bottom = -12
	outer.add_theme_constant_override("separation", 8)
	add_child(outer)

	var title := Label.new()
	title.text = "SQLite Viewer"
	title.add_theme_font_size_override("font_size", 20)
	outer.add_child(title)

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 10)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# LEFT: list of tables. Width-constrained so it doesn't eat the whole panel.
	_tables = ItemList.new()
	_tables.custom_minimum_size = Vector2(160, 0)
	_tables.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tables.item_selected.connect(_on_table_selected)
	split.add_child(_tables)

	# RIGHT: table contents in a Tree (gives us free column headers + alignment).
	_grid = Tree.new()
	_grid.column_titles_visible = true
	_grid.hide_root = true
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Click a column header → sort by that column (toggle asc/desc on repeat).
	_grid.column_title_clicked.connect(_on_column_title_clicked)
	split.add_child(_grid)

	# Footer: status + close.
	var footer := HBoxContainer.new()
	outer.add_child(footer)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.add_theme_color_override("font_color", Color(0.70, 0.65, 0.55))
	footer.add_child(_status)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(_refresh_tables)
	footer.add_child(refresh)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func(): visible = false)
	footer.add_child(close)

	_refresh_tables()


# Walk sqlite_master, populate the left-hand table list. Auto-loads the
# first table's rows so the panel isn't empty on first open.
func _refresh_tables() -> void:
	_tables.clear()
	_grid.clear()
	if GameState == null or GameState.db == null:
		_status.text = "GameState DB not available."
		return
	GameState.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
	var names: Array = []
	for row in GameState.db.query_result:
		names.append(str(row.get("name", "")))
	for n in names:
		_tables.add_item(n)
	if not names.is_empty():
		_tables.select(0)
		_load_table(names[0])
	else:
		_status.text = "No tables in DB."


# Click handler for the table list.
func _on_table_selected(idx: int) -> void:
	if idx < 0 or idx >= _tables.item_count:
		return
	_load_table(_tables.get_item_text(idx))


# Fetch the table's columns + rows once, cache them, then hand off to
# _render_grid for layout. Sort clicks re-render without re-querying.
func _load_table(table_name: String) -> void:
	if GameState == null or GameState.db == null:
		return
	# Double-quote the identifier so reserved words / spaces work.
	var quoted := '"%s"' % table_name.replace('"', '""')

	GameState.db.query("PRAGMA table_info(%s);" % quoted)
	var columns: Array = []
	for row in GameState.db.query_result:
		columns.append(str(row.get("name", "")))
	if columns.is_empty():
		_grid.clear()
		_status.text = "%s has no columns?" % table_name
		return

	GameState.db.query("SELECT * FROM %s LIMIT %d;" % [quoted, ROW_LIMIT])
	var rows: Array = GameState.db.query_result.duplicate()

	# Count total rows separately so we can report truncation.
	GameState.db.query("SELECT COUNT(*) AS n FROM %s;" % quoted)
	var total: int = 0
	if not GameState.db.query_result.is_empty():
		total = int(GameState.db.query_result[0].get("n", 0))

	_current_table = table_name
	_current_cols  = columns
	_current_rows  = rows
	# Reset sort state on table change.
	_sort_col = -1
	_sort_asc = true
	_render_grid(total)


# Build / rebuild the Tree from the cached column + row data. Called by
# _load_table and by the column-click sort handler.
func _render_grid(total_rows_in_db: int) -> void:
	_grid.clear()
	if _current_cols.is_empty():
		return
	_grid.columns = _current_cols.size()
	for i in range(_current_cols.size()):
		# Append ▲/▼ marker if this is the active sort column.
		var marker := ""
		if i == _sort_col:
			marker = "  ▲" if _sort_asc else "  ▼"
		_grid.set_column_title(i, str(_current_cols[i]) + marker)
		# Let each column expand to fill, but give it a sensible minimum
		# so short headers don't squish into one or two characters.
		_grid.set_column_expand(i, true)
		_grid.set_column_custom_minimum_width(i, 110)
		# Allow text to expand within the cell instead of being clipped to
		# the column width — better for long values like full lord names.
		_grid.set_column_clip_content(i, false)

	var root: TreeItem = _grid.create_item()
	for r in _current_rows:
		var item: TreeItem = _grid.create_item(root)
		for i in range(_current_cols.size()):
			var v = r.get(_current_cols[i], "")
			item.set_text(i, str(v) if v != null else "(null)")

	if total_rows_in_db > ROW_LIMIT:
		_status.text = "%s — showing %d of %d rows (limit %d)" % [
			_current_table, _current_rows.size(), total_rows_in_db, ROW_LIMIT
		]
	else:
		_status.text = "%s — %d rows" % [_current_table, total_rows_in_db]


# Column header click handler. First click = ascending sort by that column;
# clicking the SAME column flips to descending; clicking a different column
# starts asc again. Sort is performed on the cached rows in memory.
func _on_column_title_clicked(column: int, _mouse_button_index: int) -> void:
	if _current_cols.is_empty() or column < 0 or column >= _current_cols.size():
		return
	if column == _sort_col:
		_sort_asc = not _sort_asc
	else:
		_sort_col = column
		_sort_asc = true
	var key: String = str(_current_cols[column])
	var asc: bool = _sort_asc
	_current_rows.sort_custom(func(a, b):
		var va = a.get(key, null)
		var vb = b.get(key, null)
		# Try numeric compare first for int/float columns; fall back to string.
		if (va is int or va is float) and (vb is int or vb is float):
			return va < vb if asc else va > vb
		return str(va) < str(vb) if asc else str(va) > str(vb)
	)
	# Re-fetch total so the status line stays accurate after re-render.
	var quoted := '"%s"' % _current_table.replace('"', '""')
	GameState.db.query("SELECT COUNT(*) AS n FROM %s;" % quoted)
	var total: int = 0
	if not GameState.db.query_result.is_empty():
		total = int(GameState.db.query_result[0].get("n", 0))
	_render_grid(total)
