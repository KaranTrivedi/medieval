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


# Fetch column names via PRAGMA, then SELECT * up to ROW_LIMIT and render
# every column as a Tree column.
func _load_table(table_name: String) -> void:
	_grid.clear()
	if GameState == null or GameState.db == null:
		return
	# Use double quotes around the table name so reserved words / spaces work.
	# (None of our schema uses them, but it's the right SQL hygiene.)
	var quoted := '"%s"' % table_name.replace('"', '""')

	GameState.db.query("PRAGMA table_info(%s);" % quoted)
	var columns: Array = []
	for row in GameState.db.query_result:
		columns.append(str(row.get("name", "")))
	if columns.is_empty():
		_status.text = "%s has no columns?" % table_name
		return

	_grid.columns = columns.size()
	for i in range(columns.size()):
		_grid.set_column_title(i, columns[i])
		_grid.set_column_expand(i, true)
	var root: TreeItem = _grid.create_item()

	GameState.db.query("SELECT * FROM %s LIMIT %d;" % [quoted, ROW_LIMIT])
	var rows: Array = GameState.db.query_result
	for r in rows:
		var item: TreeItem = _grid.create_item(root)
		for i in range(columns.size()):
			var v = r.get(columns[i], "")
			item.set_text(i, str(v) if v != null else "(null)")

	# Count total rows (separate query so we know if we truncated).
	GameState.db.query("SELECT COUNT(*) AS n FROM %s;" % quoted)
	var total: int = 0
	if not GameState.db.query_result.is_empty():
		total = int(GameState.db.query_result[0].get("n", 0))
	if total > ROW_LIMIT:
		_status.text = "%s — showing %d of %d rows (limit %d)" % [
			table_name, rows.size(), total, ROW_LIMIT
		]
	else:
		_status.text = "%s — %d rows" % [table_name, total]
