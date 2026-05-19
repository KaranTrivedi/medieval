# MapData.gd
# Godot 4 Autoload Singleton — England Political Map
#
# SETUP:
#   1. Copy bg_godot.json to res://data/bg_godot.json
#   2. Project → Project Settings → Autoload → Add this script as "MapData"
#   3. Access from OTHER scripts: MapData.get_county("yorkshire")
#
# IMPORTANT: This script must NOT reference "MapData" internally.
#            Use direct function calls or "self" instead.

extends Node

# ── DATA CONTAINERS ───────────────────────────────────────────────────────────
var duchies    : Dictionary = {}
var counties   : Dictionary = {}
var baronies   : Dictionary = {}
var fiefs      : Dictionary = {}
var adjacency  : Dictionary = {}
var economy    : Dictionary = {}

var is_loaded  : bool = false
const DATA_PATH = "res://data/bg_godot.json"

# ── SIGNALS ───────────────────────────────────────────────────────────────────
signal map_loaded
signal region_conquered(county_id: String, new_earl: String, old_earl: String)

# ── LOAD ──────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_load_map()

func _load_map() -> void:
	if not FileAccess.file_exists(DATA_PATH):
		push_error("MapData: File not found at " + DATA_PATH)
		push_error("MapData: Run convert_to_godot.py first, then copy bg_godot.json to res://data/")
		return

	var file = FileAccess.open(DATA_PATH, FileAccess.READ)
	var raw = file.get_as_text()
	file.close()

	var json_parser = JSON.new()
	var err = json_parser.parse(raw)
	if err != OK:
		push_error("MapData: JSON parse error — " + json_parser.get_error_message())
		return

	var data = json_parser.get_data()

	# Duchies
	var duchy_data = data.get("duchies", {})
	for dk in duchy_data:
		duchies[dk] = duchy_data[dk]

	# Counties
	var county_data = data.get("counties", {})
	for cn in county_data:
		counties[cn] = county_data[cn]

	# Baronies
	var barony_array = data.get("baronies", [])
	for b in barony_array:
		baronies[b["id"]] = b

	# Fiefs
	var fief_array = data.get("fiefs", [])
	for f in fief_array:
		fiefs[f["id"]] = f

	# Adjacency
	adjacency = data.get("adjacency", {})

	# Economy (may be embedded in counties or separate)
	var eco_data = data.get("economy", {})
	for cid in eco_data:
		economy[cid] = eco_data[cid]

	is_loaded = true
	print("MapData: Loaded %d duchies, %d counties, %d baronies, %d fiefs." % [
		duchies.size(), counties.size(), baronies.size(), fiefs.size()
	])
	map_loaded.emit()

# ── COUNTY ACCESSORS ──────────────────────────────────────────────────────────
func get_county(county_name: String) -> Dictionary:
	return counties.get(county_name, {})

func get_all_counties() -> Array:
	return counties.values()

func get_counties_in_duchy(duchy_id: String) -> Array:
	var result: Array = []
	for cn in counties:
		if counties[cn].get("duchy", "") == duchy_id:
			result.append(counties[cn])
	return result

# ── ADJACENCY ─────────────────────────────────────────────────────────────────
func get_adjacent(county_name: String) -> Array:
	return adjacency.get(county_name, [])

func are_adjacent(county_a: String, county_b: String) -> bool:
	return county_b in get_adjacent(county_a)

func find_path(from_name: String, to_name: String) -> Array:
	if from_name == to_name:
		return [from_name]
	var visited: Dictionary = {from_name: null}
	var queue: Array = [from_name]
	while queue.size() > 0:
		var curr = queue.pop_front()
		for nb in get_adjacent(curr):
			if nb in visited:
				continue
			visited[nb] = curr
			if nb == to_name:
				var path: Array = [nb]
				var step = curr
				while step != null:
					path.push_front(step)
					step = visited.get(step)
				return path
			queue.append(nb)
	return []

# ── GEOMETRY ──────────────────────────────────────────────────────────────────
func get_polygons(county_name: String, world_scale: Vector2 = Vector2(1, 1)) -> Array:
	var co = get_county(county_name)
	if co.is_empty():
		return []
	var raw_polys: Array = co.get("polygons", [])
	var result: Array = []
	for raw_ring in raw_polys:
		# Build the scaled ring then sanitise it for Polygon2D consumption:
		#   1. drop consecutive duplicate points (degenerate edges break the
		#      triangulator and cause the fill to silently fail)
		#   2. drop the closing duplicate (Polygon2D auto-closes; an explicit
		#      last==first vertex is what was making Argyll/Galloway/etc.
		#      fail to fill while their outlines still drew)
		var ring := PackedVector2Array()
		for raw in raw_ring:
			var p := Vector2(raw[0], raw[1]) * world_scale
			if ring.size() > 0 and ring[ring.size() - 1].is_equal_approx(p):
				continue
			ring.append(p)
		if ring.size() >= 2 and ring[0].is_equal_approx(ring[ring.size() - 1]):
			ring.resize(ring.size() - 1)
		if ring.size() >= 3:
			result.append(ring)
	return result

func get_center(county_name: String, world_scale: Vector2 = Vector2(1, 1)) -> Vector2:
	var co = get_county(county_name)
	if co.is_empty():
		return Vector2.ZERO
	var c = co.get("center", {"x": 0, "y": 0})
	return Vector2(c["x"], c["y"]) * world_scale

# ── ECONOMY ───────────────────────────────────────────────────────────────────
func get_economy(county_name: String) -> Dictionary:
	var co = get_county(county_name)
	if co.has("economy"):
		return co["economy"]
	return economy.get(county_name, {})

func total_duchy_income(duchy_id: String) -> int:
	var total := 0
	for co in get_counties_in_duchy(duchy_id):
		total += co.get("income", 0)
	return total

# ── SCENE BUILDER ─────────────────────────────────────────────────────────────
func build_county_polygons(parent: Node2D, world_scale: Vector2 = Vector2(4, 4)) -> void:
	# Pull colours directly from MapData.duchies (populated from bg_godot.json)
	# so adding new duchies in the data file works without touching this code.
	#
	# Why fully opaque now: when the fill was 0.65 alpha, low-saturation
	# duchies (e.g. Lothian gold #4a4a14) blended with the default gray
	# clear-colour to a near-identical gray, making whole counties read as
	# "missing land". Once we have a parchment background sprite covering
	# the bbox, we can drop alpha back to ~0.9 to let it show through.
	const FILL_ALPHA := 1.0
	var duchy_colors: Dictionary = {}
	for did in duchies:
		var hex := str(duchies[did].get("color", "#666666"))
		var c := Color.html(hex) if hex.begins_with("#") else Color(0.2, 0.2, 0.2)
		c.a = FILL_ALPHA
		duchy_colors[did] = c

	var count := 0
	for cn in counties:
		var co = counties[cn]
		var polys = get_polygons(cn, world_scale)
		if polys.is_empty():
			continue

		var largest_ring = polys[0]
		var largest_size = 0
		for ring in polys:
			if ring.size() > largest_size:
				largest_size = ring.size()
				largest_ring = ring

		var poly2d = Polygon2D.new()
		poly2d.name = cn.replace(" ", "_")
		poly2d.polygon = largest_ring
		poly2d.color = duchy_colors.get(co.get("duchy", ""), Color(0.2, 0.2, 0.2, FILL_ALPHA))

		poly2d.set_meta("county_name", cn)
		poly2d.set_meta("duchy", co.get("duchy", ""))
		poly2d.set_meta("earl", co.get("earl", ""))
		poly2d.set_meta("income", co.get("income", 0))
		poly2d.set_meta("garrison", co.get("garrison", 0))
		poly2d.set_meta("population", co.get("population", 0))

		parent.add_child(poly2d)

		for i in range(polys.size()):
			if polys[i] == largest_ring:
				continue
			if polys[i].size() < 5:
				continue
			var extra = Polygon2D.new()
			extra.name = cn.replace(" ", "_") + "_part" + str(i)
			extra.polygon = polys[i]
			extra.color = poly2d.color
			extra.set_meta("county_name", cn)
			parent.add_child(extra)

		count += 1

	print("MapData: Built %d county Polygon2D nodes." % count)


# Draw outlines around every county. Adjacent same-duchy counties share the
# same fill colour, so without borders they read as one blob.
#
# We do two passes:
#   1. THIN county lines (every county, dark brown).
#   2. THICK duchy lines (only counties that touch a different duchy, slightly
#      different colour, drawn on TOP of the county lines so duchy boundaries
#      visually dominate.
#
# Note the duchy pass is an approximation: a duchy-edge county gets its WHOLE
# outline thickened, not just the edge facing the other duchy. To do the
# precise version we'd union all county polygons per duchy with
# Geometry2D.merge_polygons and trace the union outline — heavier and only
# worth it if the approximation reads wrong in playtest.
#
# Args:
#   parent (Node2D): typically the BorderLayer node from CampaignMap.tscn.
#   world_scale (Vector2): same scale used in build_county_polygons.
# Returns: void
func build_county_borders(parent: Node2D, world_scale: Vector2 = Vector2(4, 4)) -> void:
	const COUNTY_BORDER_COLOR := Color(0.08, 0.05, 0.02, 0.90)
	const COUNTY_BORDER_WIDTH := 4.0
	const DUCHY_BORDER_COLOR  := Color(0.02, 0.01, 0.00, 1.00)
	const DUCHY_BORDER_WIDTH  := 12.0
	const MIN_RING_PTS := 4

	var county_lines := 0
	var duchy_lines := 0

	# Pass 1: thin county outlines for every ring of every county.
	for cn in counties:
		var polys := get_polygons(cn, world_scale)
		for ring in polys:
			if ring.size() < MIN_RING_PTS:
				continue
			var line := Line2D.new()
			line.points = ring
			line.closed = true
			line.width = COUNTY_BORDER_WIDTH
			line.default_color = COUNTY_BORDER_COLOR
			line.joint_mode = Line2D.LINE_JOINT_ROUND
			parent.add_child(line)
			county_lines += 1

	# Pass 2: thicker duchy outlines, only for counties that border a different
	# duchy. Drawn after the thin pass so they layer on top.
	for cn in counties:
		var co: Dictionary = counties[cn]
		var my_duchy: String = co.get("duchy", "")
		var on_duchy_edge := false
		for nb_cn in get_adjacent(cn):
			if str(counties.get(nb_cn, {}).get("duchy", "")) != my_duchy:
				on_duchy_edge = true
				break
		if not on_duchy_edge:
			continue
		var polys := get_polygons(cn, world_scale)
		for ring in polys:
			if ring.size() < MIN_RING_PTS:
				continue
			var line := Line2D.new()
			line.points = ring
			line.closed = true
			line.width = DUCHY_BORDER_WIDTH
			line.default_color = DUCHY_BORDER_COLOR
			line.joint_mode = Line2D.LINE_JOINT_ROUND
			parent.add_child(line)
			duchy_lines += 1

	print("MapData: Built %d county borders + %d duchy borders." % [county_lines, duchy_lines])


# Place duchy-level and county-level labels in the given LabelLayer. Each
# label is created once with its zoom-band stored as metadata; CampaignMap
# toggles visibility based on the camera zoom.
#
# Args:
#   parent (Node2D): typically the LabelLayer node from CampaignMap.tscn.
#   world_scale (Vector2): same scale as the polygons.
# Returns: void
func build_labels(parent: Node2D, world_scale: Vector2 = Vector2(4, 4)) -> void:
	# County labels: at each county's stored centre.
	for cn in counties:
		var co: Dictionary = counties[cn]
		var c = co.get("center", {"x": 0, "y": 0})
		var pos := Vector2(c["x"], c["y"]) * world_scale
		parent.add_child(_make_label(cn, pos, 36, "county"))

	# Duchy labels: at the average of member counties' centres. This is a
	# rough centroid — fine for label placement. Drawn larger so they read
	# clearly when zoomed out.
	var duchy_sums: Dictionary = {}   # duchy_id → {sum: Vector2, n: int}
	for cn in counties:
		var co: Dictionary = counties[cn]
		var did = co.get("duchy", "")
		if did == "":
			continue
		var c = co.get("center", {"x": 0, "y": 0})
		var pos := Vector2(c["x"], c["y"]) * world_scale
		var bucket: Dictionary = duchy_sums.get(did, {"sum": Vector2.ZERO, "n": 0})
		bucket.sum += pos
		bucket.n += 1
		duchy_sums[did] = bucket

	for did in duchy_sums:
		var bucket: Dictionary = duchy_sums[did]
		var centroid: Vector2 = bucket.sum / float(bucket.n)
		var name: String = str(duchies.get(did, {}).get("name", did)).to_upper()
		parent.add_child(_make_label(name, centroid, 64, "duchy"))

	print("MapData: Built %d labels." % parent.get_child_count())


# Helper: build one styled Label centred on world_pos, tagged with its zoom band.
# Centring is approximate (offset by half a guesstimated text width) because
# Label.size isn't computed until the node enters the tree.
func _make_label(text: String, world_pos: Vector2, font_size: int, band: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78))
	lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.01, 0.95))
	lbl.add_theme_constant_override("outline_size", 4)
	# Approximate centring: half-char-width × text length. Tweakable.
	var est_half_w: float = font_size * 0.28 * float(text.length())
	var est_half_h: float = font_size * 0.55
	lbl.position = world_pos - Vector2(est_half_w, est_half_h)
	lbl.set_meta("zoom_band", band)
	return lbl
