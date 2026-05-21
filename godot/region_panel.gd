# region_panel.gd
# Centred Panel with three tabs covering one region: Economy, Politics, and
# Subregions. Same panel scene serves all four tiers (country/duchy/county/
# barony) — content shape changes per tier but layout stays consistent.
#
# Open via `show_for(region_type, region_id)` from CampaignMap's InfoPanel.

extends Panel

# UITheme is a global class via `class_name UITheme`. DataTable is loaded via
# preload because it's a scripted Control without a global class name.
const DataTable := preload("res://data_table.gd")

signal closed
signal open_holder_character(character_id: int)
signal navigate_region(region_type: String, region_id: String)

var _region_type: String = ""
var _region_id: String = ""
var _root: VBoxContainer
var _tabs: TabContainer


func _ready() -> void:
	custom_minimum_size = Vector2(880, 640)
	mouse_filter = Control.MOUSE_FILTER_STOP
	UITheme.style_panel(self)

	_root = VBoxContainer.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.offset_left = 8
	_root.offset_top = 8
	_root.offset_right = -8
	_root.offset_bottom = -8
	_root.add_theme_constant_override("separation", 10)
	add_child(_root)
	visible = false


# Esc closes the panel, mirroring the project-wide design principle.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			accept_event()


func show_for(region_type: String, region_id: String) -> void:
	_region_type = region_type
	_region_id = region_id
	_rebuild()
	visible = true
	var p := get_parent()
	if p != null:
		p.move_child(self, p.get_child_count() - 1)


func close() -> void:
	visible = false
	closed.emit()


# ── BUILDERS ─────────────────────────────────────────────────────────────────

func _rebuild() -> void:
	for c in _root.get_children():
		c.queue_free()

	_root.add_child(_build_header())
	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_stylebox_override("panel", UITheme.tab_panel_stylebox())
	_root.add_child(_tabs)

	_tabs.add_child(_build_economy_tab())
	_tabs.add_child(_build_politics_tab())
	_tabs.add_child(_build_offices_tab())
	_tabs.add_child(_build_subregions_tab())
	_tabs.set_tab_title(0, "Economy")
	_tabs.set_tab_title(1, "Ownership")
	_tabs.set_tab_title(2, "Offices")
	_tabs.set_tab_title(3, "Subregions")


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	# Tier label (small caps, gold).
	var tier_lbl := Label.new()
	tier_lbl.text = _region_type.to_upper()
	tier_lbl.add_theme_font_size_override("font_size", 11)
	tier_lbl.add_theme_color_override("font_color", UITheme.COL_ACCENT_GOLD_DIM)
	tier_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(tier_lbl)
	# Name (big, signature gold per tier).
	var name_lbl := Label.new()
	name_lbl.text = _pretty_name()
	name_lbl.add_theme_font_size_override("font_size", 24)
	name_lbl.add_theme_color_override("font_color", _tier_color())
	name_lbl.add_theme_constant_override("outline_size", 1)
	name_lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.01))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)
	# Close button.
	var close_btn := UITheme.styled_button("Close")
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	return row


func _build_economy_tab() -> Control:
	var col := VBoxContainer.new()
	col.name = "Economy"
	col.add_theme_constant_override("separation", 8)
	var totals: Dictionary = _aggregate_economy()
	# Big-stat row.
	var stats := GridContainer.new()
	stats.columns = 3
	stats.add_theme_constant_override("h_separation", 24)
	stats.add_theme_constant_override("v_separation", 4)
	col.add_child(stats)
	_add_big_stat(stats, "Income", "%s £/yr" % _fmt_thousands(int(totals.get("income", 0))))
	_add_big_stat(stats, "Garrison", "%s troops" % _fmt_thousands(int(totals.get("garrison", 0))))
	_add_big_stat(stats, "Population", _fmt_thousands(int(totals.get("population", 0))))
	col.add_child(UITheme.section_header("Breakdown"))
	# Per-tier breakdown text. Counties/duchies get a per-barony share table
	# below; baronies just show their own numbers.
	var sub: Array = _subregion_rows()
	if sub.is_empty():
		col.add_child(UITheme.dim_label("No sub-regions to break down.", 12))
	else:
		var t := DataTable.new()
		t.size_flags_vertical = Control.SIZE_EXPAND_FILL
		t.set_columns([
			{"key": "name",       "label": "Region",     "align": "left",  "width": 220},
			{"key": "income",     "label": "Income £",   "align": "right", "format": "int_thousands", "width": 90},
			{"key": "garrison",   "label": "Garrison",   "align": "right", "format": "int_thousands", "width": 90},
			{"key": "population", "label": "Population", "align": "right", "format": "int_thousands", "width": 110},
		])
		t.set_rows(sub)
		t.row_clicked.connect(_on_subregion_clicked)
		col.add_child(t)
	return col


func _build_politics_tab() -> Control:
	var col := VBoxContainer.new()
	col.name = "Politics"
	col.add_theme_constant_override("separation", 8)
	# Holder row.
	var holder: Dictionary = GameState.holder_of(_region_type, _region_id)
	col.add_child(UITheme.section_header("Holder"))
	col.add_child(_holder_card(holder))
	# Liege chain — walk parent_region all the way up.
	col.add_child(UITheme.section_header("Liege chain"))
	var chain: Array = _liege_chain()
	if chain.is_empty():
		col.add_child(UITheme.dim_label("(no liege — top of hierarchy)", 12))
	else:
		for link in chain:
			col.add_child(_holder_card(link))
	# Vassals — direct children regions.
	col.add_child(UITheme.section_header("Vassals"))
	var vassals: Array = _vassal_rows()
	if vassals.is_empty():
		col.add_child(UITheme.dim_label("(no sub-region holders)", 12))
	else:
		var t := DataTable.new()
		t.size_flags_vertical = Control.SIZE_EXPAND_FILL
		t.set_columns([
			{"key": "region_name", "label": "Region",   "align": "left",  "width": 200},
			{"key": "title",       "label": "Title",    "align": "left",  "width": 80},
			{"key": "holder_name", "label": "Holder",   "align": "left",  "width": 200},
			{"key": "age",         "label": "Age",      "align": "right", "format": "int", "width": 60},
		])
		t.set_rows(vassals)
		t.row_clicked.connect(_on_vassal_row_clicked)
		col.add_child(t)
	return col


# Offices tab — lists every office slot for this region's tier with its
# current holder, or "Vacant" if unappointed. Office keys come from
# GameState.OFFICES_BY_TIER; labels from OFFICE_LABELS. Each filled slot's
# name is a button that opens the holder's character panel.
func _build_offices_tab() -> Control:
	var col := VBoxContainer.new()
	col.name = "Offices"
	col.add_theme_constant_override("separation", 8)
	var slots: Array = GameState.OFFICES_BY_TIER.get(_region_type, [])
	if slots.is_empty():
		col.add_child(UITheme.dim_label("This tier has no recorded offices.", 12))
		return col
	col.add_child(UITheme.section_header(
		"%s court — %d office slot%s" % [
			_region_type.capitalize(), slots.size(),
			"" if slots.size() == 1 else "s",
		]))
	for office_key in slots:
		col.add_child(_office_row(str(office_key)))
	return col


# Single row in the Offices tab: label (left), holder (clickable button)
# or "— Vacant —". Office-key label is gold so it visually stands out.
func _office_row(office_key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label_text: String = str(GameState.OFFICE_LABELS.get(office_key, office_key.capitalize()))
	var name_lbl := UITheme.text_label(label_text, 13, UITheme.COL_ACCENT_GOLD_DIM)
	name_lbl.custom_minimum_size.x = 160
	row.add_child(name_lbl)
	var holder: Dictionary = GameState.office_holder(_region_type, _region_id, office_key)
	if holder.is_empty():
		var vacant := UITheme.dim_label("— Vacant —", 12)
		vacant.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(vacant)
	else:
		var alive: bool = bool(holder.get("alive", true))
		var person_btn := Button.new()
		person_btn.flat = true
		var dagger: String = "  ✝" if not alive else ""
		person_btn.text = "%s %s%s" % [
			str(holder.get("given_name", "")), str(holder.get("surname", "")), dagger,
		]
		person_btn.add_theme_font_size_override("font_size", 13)
		person_btn.add_theme_color_override("font_color",
				UITheme.COL_INK_DEAD if not alive else UITheme.COL_INK)
		person_btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
		person_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		person_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cid: int = int(holder.get("character_id", 0))
		person_btn.pressed.connect(func(): open_holder_character.emit(cid))
		row.add_child(person_btn)
		var age := UITheme.dim_label("· %d" % int(holder.get("age", 0)), 11)
		row.add_child(age)
	return row


func _build_subregions_tab() -> Control:
	var col := VBoxContainer.new()
	col.name = "Subregions"
	col.add_theme_constant_override("separation", 8)
	var children: Array = GameState.child_regions(_region_type, _region_id)
	if children.is_empty():
		col.add_child(UITheme.dim_label("This region has no sub-regions (deepest tier).", 12))
		return col
	col.add_child(UITheme.section_header(
			"%d %s" % [children.size(), _child_tier_label(children.size())]))
	var sub: Array = _subregion_rows()
	var t := DataTable.new()
	t.size_flags_vertical = Control.SIZE_EXPAND_FILL
	t.set_columns([
		{"key": "name",       "label": "Name",        "align": "left",  "width": 220},
		{"key": "income",     "label": "💰 Income",    "align": "right", "format": "int_thousands", "width": 110},
		{"key": "garrison",   "label": "⚔ Garrison",  "align": "right", "format": "int_thousands", "width": 110},
		{"key": "population", "label": "👥 People",   "align": "right", "format": "int_thousands", "width": 110},
	])
	t.set_rows(sub)
	t.row_clicked.connect(_on_subregion_clicked)
	col.add_child(t)
	return col


# ── DATA HELPERS ─────────────────────────────────────────────────────────────

# Pretty-print the region's display name (handles each tier's id flavour).
func _pretty_name() -> String:
	match _region_type:
		"country": return _region_id.capitalize()
		"duchy":
			var d: Dictionary = MapData.duchies.get(_region_id, {})
			return str(d.get("name", _region_id))
		"county": return _region_id
		"barony": return MapData.barony_name(_region_id)
	return _region_id


func _tier_color() -> Color:
	match _region_type:
		"country": return UITheme.COL_TIER_COUNTRY
		"duchy":   return UITheme.COL_TIER_DUCHY
		"county":  return UITheme.COL_TIER_COUNTY
		"barony":  return UITheme.COL_TIER_BARONY
	return UITheme.COL_INK


# Top-line totals depending on tier. Country/duchy aggregate via MapData,
# county sums its baronies, barony reads its own row.
func _aggregate_economy() -> Dictionary:
	match _region_type:
		"country": return MapData.aggregate_country(_region_id.capitalize())
		"duchy":
			var d: Dictionary = MapData.aggregate_duchy(_region_id)
			d["income"] = d.get("total_income", 0)
			return d
		"county":
			var co: Dictionary = MapData.get_county(_region_id)
			return {"income": int(co.get("income", 0)),
					"garrison": int(co.get("garrison", 0)),
					"population": int(co.get("population", 0))}
		"barony":
			var dd: Node = get_node_or_null("/root/DesignData")
			if dd != null:
				return dd.barony_economy(_region_id)
	return {}


# Build the row list for the Subregions / Economy tabs.
func _subregion_rows() -> Array:
	var out: Array = []
	for child in GameState.child_regions(_region_type, _region_id):
		var rt: String = child.region_type
		var rid: String = child.region_id
		var rname: String = rid
		var income: int = 0
		var garrison: int = 0
		var pop: int = 0
		match rt:
			"duchy":
				rname = str(MapData.duchies.get(rid, {}).get("name", rid))
				var d: Dictionary = MapData.aggregate_duchy(rid)
				income = int(d.get("total_income", 0))
				garrison = int(d.get("garrison", 0))
				pop = int(d.get("population", 0))
			"county":
				var co: Dictionary = MapData.get_county(rid)
				income = int(co.get("income", 0))
				garrison = int(co.get("garrison", 0))
				pop = int(co.get("population", 0))
			"barony":
				var dd: Node = get_node_or_null("/root/DesignData")
				if dd != null:
					var b: Dictionary = dd.barony_economy(rid)
					income = int(b.get("income", 0))
					garrison = int(b.get("garrison", 0))
					pop = int(b.get("population", 0))
				# Always pull the readable name from MapData — design overrides
				# only carry "name" for the handful of marked baronies (London,
				# York, …); the rest get their LAD13NM via the geometry layer.
				rname = MapData.barony_name(rid)
		out.append({
			"region_type": rt, "region_id": rid, "name": rname,
			"income": income, "garrison": garrison, "population": pop,
		})
	return out


# Walk parent_region(...) upward until no parent exists. Returns liege rows.
func _liege_chain() -> Array:
	var chain: Array = []
	var cur_type: String = _region_type
	var cur_id: String = _region_id
	while true:
		var parent: Dictionary = GameState.parent_region(cur_type, cur_id)
		if parent.is_empty():
			break
		var h: Dictionary = GameState.holder_of(parent.region_type, parent.region_id)
		if h.is_empty():
			break
		h["region_type"] = parent.region_type
		h["region_id"] = parent.region_id
		chain.append(h)
		cur_type = parent.region_type
		cur_id = parent.region_id
	return chain


# Holder rows for the Vassals table: one row per sub-region with its holder.
func _vassal_rows() -> Array:
	var rows: Array = []
	for child in GameState.child_regions(_region_type, _region_id):
		var h: Dictionary = GameState.holder_of(child.region_type, child.region_id)
		if h.is_empty():
			continue
		var rname: String = child.region_id
		match str(child.region_type):
			"duchy":  rname = str(MapData.duchies.get(child.region_id, {}).get("name", child.region_id))
			"barony": rname = MapData.barony_name(child.region_id)
		rows.append({
			"region_type": child.region_type,
			"region_id": child.region_id,
			"region_name": rname,
			"title": str(h.get("title", "")),
			"holder_name": "%s %s" % [str(h.get("given_name", "")), str(h.get("surname", ""))],
			"age": int(h.get("age", 0)),
			"character_id": int(h.get("character_id", 0)),
		})
	return rows


# Friendly plural tier label for the children of this region.
func _child_tier_label(_n: int) -> String:
	match _region_type:
		"country": return "Duchies"
		"duchy":   return "Counties"
		"county":  return "Baronies"
	return "Regions"


# A small clickable row showing a holder's name + title + region context.
func _holder_card(holder: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.chip_stylebox(false))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)
	var title_str: String = "%s of %s" % [str(holder.get("title", "Lord")),
			str(holder.get("region_id", _region_id)).capitalize()]
	var l := Label.new()
	l.text = title_str
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", UITheme.COL_INK_DIM)
	l.custom_minimum_size.x = 180
	row.add_child(l)
	# Holder name as a clickable button → opens character panel.
	var name_btn := Button.new()
	name_btn.flat = true
	name_btn.text = "%s %s" % [str(holder.get("given_name", "")), str(holder.get("surname", ""))]
	name_btn.add_theme_font_size_override("font_size", 13)
	name_btn.add_theme_color_override("font_color", UITheme.COL_INK)
	name_btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cid: int = int(holder.get("character_id", 0))
	name_btn.pressed.connect(func(): open_holder_character.emit(cid))
	row.add_child(name_btn)
	# Age tag.
	var age := Label.new()
	age.text = "· %d" % int(holder.get("age", 0))
	age.add_theme_font_size_override("font_size", 11)
	age.add_theme_color_override("font_color", UITheme.COL_INK_MUTED)
	row.add_child(age)
	return card


# ── EVENT HANDLERS ───────────────────────────────────────────────────────────

func _on_subregion_clicked(row: Dictionary) -> void:
	# Navigate into the sub-region — same panel rebuilds.
	var rt: String = str(row.get("region_type", ""))
	var rid: String = str(row.get("region_id", ""))
	if rt == "" or rid == "":
		return
	navigate_region.emit(rt, rid)
	show_for(rt, rid)


func _on_vassal_row_clicked(row: Dictionary) -> void:
	var cid: int = int(row.get("character_id", 0))
	if cid > 0:
		open_holder_character.emit(cid)


# ── SMALL UI HELPERS ─────────────────────────────────────────────────────────

func _add_big_stat(grid: GridContainer, label: String, value: String) -> void:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 0)
	var l := Label.new()
	l.text = label.to_upper()
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", UITheme.COL_INK_MUTED)
	cell.add_child(l)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 18)
	v.add_theme_color_override("font_color", UITheme.COL_INK)
	cell.add_child(v)
	grid.add_child(cell)


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
