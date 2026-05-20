# ui_panel.gd
# Right-side InfoPanel. Hidden by default. Rebuilds its contents from scratch
# every time CampaignMap calls update_panel_typed() — that way each region
# tier (country/duchy/county/barony) gets its own bespoke layout instead of
# the previous repurposed-rows hack.

extends CanvasLayer

@onready var info_panel: Panel       = $Control/InfoPanel
@onready var vbox: VBoxContainer     = $Control/InfoPanel/VBoxContainer
@onready var character_panel: Panel  = $Control/CharacterPanel
@onready var family_tree_panel: Panel = $Control/FamilyTreePanel

# Emitted when the holder name in the InfoPanel is clicked. Listeners get the
# character_id so they can open the character overview.
signal holder_clicked(character_id: int)

# Emitted when the "Details" button at the bottom of the InfoPanel is clicked.
# Carries the (region_type, region_id) so CampaignMap can open RegionPanel.
signal region_details_requested(region_type: String, region_id: String)

const UITheme := preload("res://ui_theme.gd")

# Big colour values for headers per region tier — gives each tier a distinct
# visual identity in the panel header.
const HEADER_COLORS := {
	"country": Color(0.96, 0.78, 0.30),    # gold
	"duchy":   Color(0.92, 0.65, 0.40),    # bronze
	"county":  Color(0.88, 0.78, 0.55),    # parchment
	"barony":  Color(0.75, 0.70, 0.55),    # muted earth
}


func _ready() -> void:
	info_panel.visible = false
	visible = true


# Hide the panel and drop any built-up content.
func clear_panel() -> void:
	info_panel.visible = false
	_clear_children()


# Show the panel and build a tier-specific layout from `data`.
#
# Required keys: "type" (one of country/duchy/county/barony) and "name".
# Extra keys are read per tier — see the individual _build_* functions.
func update_panel_typed(data: Dictionary) -> void:
	info_panel.visible = true
	_clear_children()
	match str(data.get("type", "")):
		"country": _build_country(data)
		"duchy":   _build_duchy(data)
		"county":  _build_county(data)
		"barony":  _build_barony(data)


# ── PER-TIER BUILDERS ─────────────────────────────────────────────────────────

func _build_country(d: Dictionary) -> void:
	_add_header(d.get("name", ""), "country", "Country")
	_add_holder_row(d.get("holder", {}))
	_add_kv("Duchies",       str(int(d.get("duchy_count", 0))))
	_add_kv("Counties",      str(int(d.get("county_count", 0))))
	_add_kv("Baronies",      str(int(d.get("barony_count", 0))))
	_add_kv("Total income",  "%s £/yr" % _fmt_thousands(int(d.get("total_income", 0))))
	_add_kv("Population",    _fmt_thousands(int(d.get("population", 0))))
	_add_kv("Garrison",      "%s troops" % _fmt_thousands(int(d.get("garrison", 0))))
	_add_details_button("country", str(d.get("id", str(d.get("name", "")).to_lower())))


func _build_duchy(d: Dictionary) -> void:
	_add_header(d.get("name", ""), "duchy", "Duchy")
	_add_holder_row(d.get("holder", {}))
	_add_kv("Counties",      str(int(d.get("county_count", 0))))
	_add_kv("Baronies",      str(int(d.get("barony_count", 0))))
	_add_kv("Total income",  "%s £/yr" % _fmt_thousands(int(d.get("total_income", 0))))
	_add_kv("Population",    _fmt_thousands(int(d.get("population", 0))))
	_add_kv("Garrison",      "%s troops" % _fmt_thousands(int(d.get("garrison", 0))))
	_add_details_button("duchy", str(d.get("id", "")))


func _build_county(d: Dictionary) -> void:
	_add_header(d.get("name", ""), "county", "County")
	_add_holder_row(d.get("holder", {}))
	_add_kv("Duchy",         str(d.get("duchy", "—")).capitalize())
	_add_kv("Baronies",      str(int(d.get("baronies", []).size())))
	_add_kv("Income",        "%s £/yr" % _fmt_thousands(int(d.get("income", 0))))
	_add_kv("Population",    _fmt_thousands(int(d.get("population", 0))))
	_add_kv("Garrison",      "%s troops" % _fmt_thousands(int(d.get("garrison", 0))))
	_add_details_button("county", str(d.get("name", "")))


func _build_barony(d: Dictionary) -> void:
	_add_header(d.get("name", ""), "barony", "Barony")
	_add_holder_row(d.get("holder", {}))
	_add_kv("County",        str(d.get("county", "—")))
	_add_kv("Income",        "%s £/yr" % _fmt_thousands(int(d.get("income", 0))))
	_add_kv("Population",    _fmt_thousands(int(d.get("population", 0))))
	_add_kv("Garrison",      "%s troops" % _fmt_thousands(int(d.get("garrison", 0))))
	_add_details_button("barony", str(d.get("id", "")))


# A footer button that opens RegionPanel (Economy/Politics/Subregions tabs)
# for the region currently being displayed. The button is suppressed when no
# region_id can be derived (shouldn't happen — every tier passes one).
func _add_details_button(region_type: String, region_id: String) -> void:
	if region_id == "":
		return
	# Spacer separating the kv rows from the action button.
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	vbox.add_child(spacer)
	var btn := UITheme.styled_button("📜  View region details")
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func(): region_details_requested.emit(region_type, region_id))
	vbox.add_child(btn)


# Render the current holder + house, plus the holder's age. The holder name
# is a flat Button so clicking it opens the character overview.
func _add_holder_row(h: Dictionary) -> void:
	if h.is_empty():
		return
	var title: String = str(h.get("title", "Holder"))
	var given: String = str(h.get("given_name", "")).strip_edges()
	var surname: String = str(h.get("surname", "")).strip_edges()
	var full_name: String = (given + " " + surname).strip_edges()
	if full_name == "":
		full_name = "Unknown"
	var character_id: int = int(h.get("character_id", 0))
	_add_clickable_kv(title, full_name, character_id)
	if surname != "":
		_add_kv("House", surname)
	if int(h.get("age", 0)) > 0:
		_add_kv("Age", str(int(h.get("age"))))


# Variant of _add_kv where the VALUE is a flat Button — clicking it emits
# `holder_clicked(character_id)` so the rest of the UI can open the character
# overview. Skips the button (falls back to a plain label) when character_id
# is 0, which happens for regions with no recorded holder.
func _add_clickable_kv(key: String, value: String, character_id: int) -> void:
	if character_id <= 0:
		_add_kv(key, value)
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var k := Label.new()
	k.text = key
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	k.add_theme_font_size_override("font_size", 12)
	k.add_theme_color_override("font_color", Color(0.65, 0.60, 0.50))
	row.add_child(k)

	var btn := Button.new()
	btn.text = value
	btn.flat = true
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", Color(0.95, 0.92, 0.80))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.55))
	btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	btn.pressed.connect(func(): holder_clicked.emit(character_id))
	row.add_child(btn)


# ── HELPERS ───────────────────────────────────────────────────────────────────

func _clear_children() -> void:
	for child in vbox.get_children():
		child.queue_free()


# Add a styled header row. `caption` is the small all-caps tier label,
# `name` is the region name.
func _add_header(name: String, tier_key: String, caption: String) -> void:
	var cap := Label.new()
	cap.text = caption.to_upper()
	cap.add_theme_font_size_override("font_size", 11)
	cap.add_theme_color_override("font_color", Color(0.85, 0.80, 0.65))
	vbox.add_child(cap)

	var name_lbl := Label.new()
	name_lbl.text = str(name)
	name_lbl.add_theme_font_size_override("font_size", 22)
	name_lbl.add_theme_color_override("font_color", HEADER_COLORS.get(tier_key, Color.WHITE))
	name_lbl.add_theme_constant_override("outline_size", 1)
	name_lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.01))
	vbox.add_child(name_lbl)

	var sep := HSeparator.new()
	vbox.add_child(sep)


# Add a key/value row. Caption on the left, value right-aligned.
func _add_kv(key: String, value: String) -> void:
	var row := HBoxContainer.new()
	row.theme_type_variation = ""
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var k := Label.new()
	k.text = key
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	k.add_theme_font_size_override("font_size", 12)
	k.add_theme_color_override("font_color", Color(0.65, 0.60, 0.50))
	row.add_child(k)

	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 13)
	v.add_theme_color_override("font_color", Color(0.95, 0.92, 0.80))
	row.add_child(v)


# Format an integer with comma thousands separators ("12345" → "12,345").
# Built-in GDScript has nothing equivalent.
func _fmt_thousands(n: int) -> String:
	var s := str(n)
	var sign := ""
	if s.begins_with("-"):
		sign = "-"
		s = s.substr(1)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count == 3 and i > 0:
			out = "," + out
			count = 0
	return sign + out
