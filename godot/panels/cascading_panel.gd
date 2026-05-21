# cascading_panel.gd
# Modal Panel that shows the political hierarchy as a collapsable Tree:
#
#   ENGLAND
#     └ Duchy of Lancaster
#         └ Yorkshire
#             ├ Selby District (barony)
#             ├ ...
#
# Each row shows aggregated stats (population, income, child count) so the
# user can drill in to see what each tier contains. Future fief / city /
# resource layers slot in below the barony row by extending _populate_county.

extends Panel

@onready var tree: Tree
@onready var status: Label

# Column indices for the Tree.
const COL_NAME := 0
const COL_POPULATION := 1
const COL_INCOME := 2
const COL_CHILDREN := 3


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
	title.text = "Realm Hierarchy"
	title.add_theme_font_size_override("font_size", 20)
	outer.add_child(title)

	tree = Tree.new()
	tree.columns = 4
	tree.column_titles_visible = true
	tree.set_column_title(COL_NAME, "Region")
	tree.set_column_title(COL_POPULATION, "Population")
	tree.set_column_title(COL_INCOME, "Income £/yr")
	tree.set_column_title(COL_CHILDREN, "Children")
	tree.set_column_expand(COL_NAME, true)
	tree.set_column_expand_ratio(COL_NAME, 3)
	tree.hide_root = true
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(tree)

	var footer := HBoxContainer.new()
	outer.add_child(footer)
	status = Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.add_theme_color_override("font_color", Color(0.70, 0.65, 0.55))
	footer.add_child(status)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(refresh_tree)
	footer.add_child(refresh)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func(): visible = false)
	footer.add_child(close)

	refresh_tree()


# Rebuild the tree from MapData. Countries are roots, duchies under each
# country, counties under each duchy, baronies under each county.
func refresh_tree() -> void:
	tree.clear()
	if MapData == null or not MapData.is_loaded:
		status.text = "Map data not loaded."
		return

	var root: TreeItem = tree.create_item()

	# 3 countries in fixed order so the layout is stable.
	var country_count: int = 0
	for country in ["England", "Wales", "Scotland"]:
		var c_stats: Dictionary = MapData.aggregate_country(country)
		var c_item: TreeItem = tree.create_item(root)
		c_item.set_text(COL_NAME, country.to_upper())
		c_item.set_text(COL_POPULATION, _fmt(c_stats.get("population", 0)))
		c_item.set_text(COL_INCOME, _fmt(c_stats.get("total_income", 0)))
		c_item.set_text(COL_CHILDREN, "%d duchies" % int(c_stats.get("duchy_count", 0)))
		c_item.collapsed = true
		_populate_duchies(c_item, country)
		country_count += 1

	status.text = "Showing %d countries · %d duchies · %d counties · %d baronies" % [
		country_count, MapData.duchies.size(), MapData.counties.size(), _barony_total()
	]


func _populate_duchies(parent_item: TreeItem, country: String) -> void:
	for did in MapData.duchies:
		if MapData.COUNTRY_BY_DUCHY.get(did, "") != country:
			continue
		var d_stats: Dictionary = MapData.aggregate_duchy(did)
		var d_item: TreeItem = tree.create_item(parent_item)
		var d_name: String = str(MapData.duchies[did].get("name", did))
		d_item.set_text(COL_NAME, d_name)
		d_item.set_text(COL_POPULATION, _fmt(d_stats.get("population", 0)))
		d_item.set_text(COL_INCOME, _fmt(d_stats.get("total_income", 0)))
		d_item.set_text(COL_CHILDREN, "%d counties" % int(d_stats.get("county_count", 0)))
		d_item.collapsed = true
		_populate_counties(d_item, did)


func _populate_counties(parent_item: TreeItem, duchy_id: String) -> void:
	for cn in MapData.counties:
		if str(MapData.counties[cn].get("duchy", "")) != duchy_id:
			continue
		var co: Dictionary = MapData.counties[cn]
		var c_item: TreeItem = tree.create_item(parent_item)
		c_item.set_text(COL_NAME, cn)
		c_item.set_text(COL_POPULATION, _fmt(co.get("population", 0)))
		c_item.set_text(COL_INCOME, _fmt(co.get("income", 0)))
		var bs: Array = co.get("baronies", [])
		c_item.set_text(COL_CHILDREN, "%d baronies" % bs.size())
		c_item.collapsed = true
		_populate_baronies(c_item, bs)


func _populate_baronies(parent_item: TreeItem, baronies: Array) -> void:
	# Per-barony numbers come from DesignData.barony_economy (via MapData),
	# which returns an explicit override for known LADs (London, York, …)
	# or a pro-rata county slice for the rest.
	var parent_county_name: String = parent_item.get_text(COL_NAME)
	for b in baronies:
		var b_id: String = str(b.get("id", ""))
		var econ: Dictionary = MapData.aggregate_barony(parent_county_name, b_id)
		# Use override name if present, else the data file's LAD13NM.
		var display_name: String = str(econ.get("name", b.get("name", b_id)))
		var b_item: TreeItem = tree.create_item(parent_item)
		b_item.set_text(COL_NAME, display_name)
		b_item.set_text(COL_POPULATION, _fmt(int(econ.get("population", 0))))
		b_item.set_text(COL_INCOME, _fmt(int(econ.get("income", 0))))
		# Reserved for future fief / city / resource expansion.
		b_item.set_text(COL_CHILDREN, "—")


# Total barony count across all counties — for the footer status line.
func _barony_total() -> int:
	var n: int = 0
	for cn in MapData.counties:
		n += int(MapData.counties[cn].get("baronies", []).size())
	return n


# Comma-thousands integer formatter — same shape as ui_panel._fmt_thousands
# but kept local to avoid coupling the two scripts.
func _fmt(v) -> String:
	var s := str(int(v))
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
