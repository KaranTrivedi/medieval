# MapData.gd
# Godot 4 Autoload Singleton — England Political Map
#
# SETUP:
#   1. Copy england_godot.json to res://data/england_godot.json
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
const DATA_PATH = "res://data/england_godot.json"

# ── SIGNALS ───────────────────────────────────────────────────────────────────
signal map_loaded
signal region_conquered(county_id: String, new_earl: String, old_earl: String)

# ── LOAD ──────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_load_map()

func _load_map() -> void:
	if not FileAccess.file_exists(DATA_PATH):
		push_error("MapData: File not found at " + DATA_PATH)
		push_error("MapData: Run convert_to_godot.py first, then copy england_godot.json to res://data/")
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
		var ring = PackedVector2Array()
		ring.resize(raw_ring.size())
		for i in raw_ring.size():
			ring[i] = Vector2(raw_ring[i][0], raw_ring[i][1]) * world_scale
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
	var duchy_colors := {
		"lancaster":  Color(0.35, 0.07, 0.07, 0.65),
		"cornwall":   Color(0.05, 0.25, 0.15, 0.65),
		"gloucester": Color(0.07, 0.11, 0.27, 0.65),
		"norfolk":    Color(0.29, 0.19, 0.0,  0.65),
		"chester":    Color(0.23, 0.06, 0.31, 0.65),
		"march":      Color(0.23, 0.15, 0.0,  0.65),
		"wales":      Color(0.04, 0.13, 0.06, 0.45),
		"scotland":   Color(0.04, 0.09, 0.16, 0.45),
	}

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
		poly2d.color = duchy_colors.get(co.get("duchy", ""), Color(0.2, 0.2, 0.2, 0.5))

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
