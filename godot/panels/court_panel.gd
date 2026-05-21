# court_panel.gd
# Player-facing court overview for a country. Shows the five great offices,
# their current holders (or "Vacant"), and the direct vassals (duchy holders)
# of the country. Clicking any name routes through NavRouter so the back /
# forward buttons can walk the visit history.
#
# Open via `show_for(country_id)` — typically from the TopBar "Court" button
# wired to NavRouter.open_court.

extends Panel

signal closed
signal open_character_request(character_id: int)
signal open_region_request(region_type: String, region_id: String)

var _country_id: String = ""
var _root: VBoxContainer
# When the user clicks "Appoint…" / "Replace…", we remember which slot
# is being filled so the candidate-row click handler knows what to write.
# Form: "<region_type>|<region_id>|<office_key>".
var _picking_slot: String = ""


func _ready() -> void:
	custom_minimum_size = Vector2(880, 640)
	mouse_filter = Control.MOUSE_FILTER_STOP
	UITheme.style_panel(self)

	_root = VBoxContainer.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.offset_left = 18
	_root.offset_top = 14
	_root.offset_right = -18
	_root.offset_bottom = -14
	_root.add_theme_constant_override("separation", 12)
	add_child(_root)
	visible = false


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			accept_event()


func show_for(country_id: String) -> void:
	_country_id = country_id
	_rebuild()
	visible = true
	var p := get_parent()
	if p != null:
		p.move_child(self, p.get_child_count() - 1)


func close() -> void:
	visible = false
	closed.emit()


# ── REBUILD ─────────────────────────────────────────────────────────────────

func _rebuild() -> void:
	for c in _root.get_children():
		c.queue_free()
	if _country_id == "":
		_root.add_child(UITheme.dim_label("No country selected.", 14))
		return

	_build_header()
	_build_offices_section()
	_build_vassals_section()
	_build_footer()


func _build_header() -> void:
	var monarch: Dictionary = GameState.holder_of("country", _country_id)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_root.add_child(row)

	var caption := Label.new()
	caption.text = "COURT OF"
	caption.add_theme_font_size_override("font_size", 11)
	caption.add_theme_color_override("font_color", UITheme.COL_ACCENT_GOLD_DIM)
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(caption)

	var title := Label.new()
	title.text = _country_id.capitalize().to_upper()
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UITheme.COL_TIER_COUNTRY)
	title.add_theme_constant_override("outline_size", 1)
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.01))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)

	if not monarch.is_empty():
		var monarch_btn := UITheme.styled_button("👑  %s %s, %s" % [
			str(monarch.get("given_name", "")), str(monarch.get("surname", "")),
			str(monarch.get("title", "Monarch")),
		])
		var cid: int = int(monarch.get("character_id", 0))
		monarch_btn.pressed.connect(func(): open_character_request.emit(cid))
		row.add_child(monarch_btn)

	# Close button pinned top-right of the header — consistent across panels.
	var close_btn := UITheme.styled_button("✕")
	close_btn.tooltip_text = "Close (Esc)"
	close_btn.pressed.connect(close)
	row.add_child(close_btn)


func _build_offices_section() -> void:
	_root.add_child(UITheme.section_header("Great Offices of the Realm"))
	var offices: Array = GameState.OFFICES_BY_TIER.get("country", [])
	for office_key in offices:
		var ok: String = str(office_key)
		_root.add_child(_office_row("country", _country_id, ok))
		# If this is the slot the user just clicked Appoint on, inline the
		# candidate picker right under it.
		if _picking_slot == _slot_key("country", _country_id, ok):
			_root.add_child(_build_picker("country", _country_id, ok))


# A single row showing one office: name + holder (or "Vacant") + appoint /
# replace / vacate buttons. Returns a Control row.
func _office_row(region_type: String, region_id: String, office_key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var name_lbl := UITheme.text_label(
		str(GameState.OFFICE_LABELS.get(office_key, office_key.capitalize())),
		13, UITheme.COL_ACCENT_GOLD_DIM)
	name_lbl.custom_minimum_size.x = 160
	row.add_child(name_lbl)

	var holder: Dictionary = GameState.office_holder(region_type, region_id, office_key)
	if holder.is_empty():
		var vacant := UITheme.dim_label("— Vacant —", 12)
		vacant.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(vacant)
		var appoint_btn := UITheme.styled_button("Appoint…")
		appoint_btn.pressed.connect(func(): _toggle_picker(region_type, region_id, office_key))
		row.add_child(appoint_btn)
	else:
		var alive: bool = bool(holder.get("alive", true))
		var person_btn := Button.new()
		person_btn.flat = true
		var dagger: String = "  ✝" if not alive else ""
		person_btn.text = "%s %s%s" % [
			str(holder.get("given_name", "")),
			str(holder.get("surname", "")),
			dagger,
		]
		person_btn.add_theme_font_size_override("font_size", 13)
		person_btn.add_theme_color_override("font_color",
			UITheme.COL_INK_DEAD if not alive else UITheme.COL_INK)
		person_btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
		person_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		person_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cid: int = int(holder.get("character_id", 0))
		person_btn.pressed.connect(func(): open_character_request.emit(cid))
		row.add_child(person_btn)
		var age := UITheme.dim_label("· %d" % int(holder.get("age", 0)), 11)
		row.add_child(age)
		var replace_btn := UITheme.styled_button("Replace…")
		replace_btn.pressed.connect(func(): _toggle_picker(region_type, region_id, office_key))
		row.add_child(replace_btn)
		var vacate_btn := UITheme.styled_button("Dismiss")
		vacate_btn.pressed.connect(func(): _vacate(region_type, region_id, office_key))
		row.add_child(vacate_btn)
	return row


# Toggle the inline candidate picker for a given slot. Calling on the same
# slot a second time collapses the picker.
func _toggle_picker(region_type: String, region_id: String, office_key: String) -> void:
	var key := _slot_key(region_type, region_id, office_key)
	_picking_slot = "" if _picking_slot == key else key
	_rebuild()


func _slot_key(region_type: String, region_id: String, office_key: String) -> String:
	return "%s|%s|%s" % [region_type, region_id, office_key]


# Build the inline candidate list shown when the user clicks Appoint /
# Replace. Each candidate is a button — clicking it calls appoint and
# collapses the picker.
func _build_picker(region_type: String, region_id: String, office_key: String) -> Control:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UITheme.chip_stylebox(false))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	box.add_child(col)
	var key_stat: String = OFFICE_KEY_STAT.get(office_key, "")
	var head_txt: String = "Select a candidate for %s" % str(GameState.OFFICE_LABELS.get(office_key, office_key.capitalize()))
	if key_stat != "":
		head_txt += "  (key stat: %s)" % key_stat.capitalize()
	col.add_child(UITheme.dim_label(head_txt + ":", 11))
	var candidates: Array = GameState.eligible_office_candidates(region_type, region_id)
	if candidates.is_empty():
		col.add_child(UITheme.dim_label("(no eligible candidates)", 11))
	else:
		var dt = preload("res://ui/data_table.gd").new()
		dt.set_columns([
			{"key": "name",              "label": "Name",     "width": 150},
			{"key": "age",               "label": "Age",      "align": "right", "format": "int", "width": 40},
			{"key": "house",             "label": "House",    "width": 90},
			{"key": "family_tier_label", "label": "Tier",     "width": 60},
			{"key": "prestige",          "label": "Prestige", "align": "right", "format": "int", "width": 60},
			{"key": "stats_brief",       "label": "Stats",    "width": 130},
			{"key": "opinion_of_liege",  "label": "OpL",      "align": "right", "format": "int", "width": 45},
			{"key": "current_office",    "label": "Office",   "width": 140},
		])
		var rows: Array = []
		for c in candidates:
			var full_name: String = (str(c.get("given_name", "")) + " " + str(c.get("surname", ""))).strip_edges()
			rows.append({
				"character_id":      int(c.get("character_id", 0)),
				"name":              full_name,
				"age":               int(c.get("age", 0)),
				"house":             str(c.get("surname", "")),
				"family_tier_label": str(c.get("family_tier_label", "")),
				"prestige":          int(c.get("prestige", 0)),
				"stats_brief":       GameState.candidate_stats_brief(c),
				"opinion_of_liege":  int(c.get("opinion_of_liege", 0)),
				"current_office":    str(c.get("current_office", "")),
			})
		dt.set_rows(rows)
		dt.row_clicked.connect(func(row):
			_appoint(region_type, region_id, office_key, int(row.get("character_id", 0))))
		col.add_child(dt)
	var cancel := UITheme.styled_button("Cancel")
	cancel.pressed.connect(func(): _toggle_picker(region_type, region_id, office_key))
	col.add_child(cancel)
	return box


# Office → primary stat lookup mirrored from region_panel.gd. Surfaced
# above the candidate table so the player knows which Stats column matters
# for this slot. Keep the two copies aligned if you add new offices.
const OFFICE_KEY_STAT: Dictionary = {
	"marshal": "martial", "constable": "martial", "castellan": "martial",
	"chancellor": "diplomacy", "seneschal": "diplomacy", "herald": "diplomacy",
	"treasurer": "stewardship", "justiciar": "stewardship", "bailiff": "stewardship",
	"reeve": "stewardship", "forester": "stewardship",
	"spymaster": "intrigue", "coroner": "intrigue",
	"chaplain": "piety",
	"sheriff": "diplomacy",
}


func _appoint(region_type: String, region_id: String, office_key: String, character_id: int) -> void:
	GameState.appoint_to_office(region_type, region_id, office_key, character_id)
	_picking_slot = ""
	_rebuild()


func _vacate(region_type: String, region_id: String, office_key: String) -> void:
	GameState.vacate_office(region_type, region_id, office_key)
	_rebuild()


func _build_vassals_section() -> void:
	_root.add_child(UITheme.section_header("Direct Vassals — Dukes"))
	# Country tier's children are the duchies.
	for child in GameState.child_regions("country", _country_id):
		_root.add_child(_vassal_row(str(child.region_type), str(child.region_id)))


func _vassal_row(region_type: String, region_id: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var region_name: String = region_id
	if region_type == "duchy":
		region_name = str(MapData.duchies.get(region_id, {}).get("name", region_id))
	# Region-name button → opens the region panel for that duchy.
	var region_btn := Button.new()
	region_btn.flat = true
	region_btn.text = region_name
	region_btn.add_theme_font_size_override("font_size", 13)
	region_btn.add_theme_color_override("font_color", UITheme.COL_TIER_DUCHY)
	region_btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
	region_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	region_btn.custom_minimum_size.x = 220
	region_btn.pressed.connect(func(): open_region_request.emit(region_type, region_id))
	row.add_child(region_btn)
	var holder: Dictionary = GameState.holder_of(region_type, region_id)
	if not holder.is_empty():
		var person_btn := Button.new()
		person_btn.flat = true
		var alive: bool = bool(holder.get("alive", true))
		var dagger: String = "  ✝" if not alive else ""
		person_btn.text = "%s %s%s" % [
			str(holder.get("given_name", "")),
			str(holder.get("surname", "")),
			dagger,
		]
		person_btn.add_theme_font_size_override("font_size", 12)
		person_btn.add_theme_color_override("font_color",
			UITheme.COL_INK_DEAD if not alive else UITheme.COL_INK)
		person_btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
		person_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		person_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cid: int = int(holder.get("character_id", 0))
		person_btn.pressed.connect(func(): open_character_request.emit(cid))
		row.add_child(person_btn)
		var age := UITheme.dim_label("· %d" % int(holder.get("age", 0)), 11)
		row.add_child(age)
	else:
		row.add_child(UITheme.dim_label("(no holder)", 11))
	return row


func _build_footer() -> void:
	# Close is in the header (top-right); footer is currently empty until
	# the player gets enough court-wide actions to justify it.
	pass
