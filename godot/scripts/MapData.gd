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
			# Was: skip rings < 5 pts. Lowered to 3 (= valid triangle) so
			# small islands aren't dropped entirely. The dedup in get_polygons
			# already removes degenerate cases.
			if polys[i].size() < 3:
				continue
			var extra = Polygon2D.new()
			extra.name = cn.replace(" ", "_") + "_part" + str(i)
			extra.polygon = polys[i]
			extra.color = poly2d.color
			extra.set_meta("county_name", cn)
			parent.add_child(extra)

		count += 1

	print("MapData: Built %d county Polygon2D nodes." % count)


# Draw ONE outline per county. The bg_godot.json data file has already
# unioned each county's LADs via shapely (in convert_to_godot.py), so we just
# render whatever polygon rings the data hands us — no in-engine merging.
#
# Two width tiers, both stored as desired SCREEN pixels rather than world
# units. CampaignMap rescales each Line2D every time the zoom changes so the
# lines look the same thickness no matter how close you are. The "screen_px"
# meta on each Line2D is what CampaignMap reads.
#
# Args:
#   parent (Node2D): typically the BorderLayer node from CampaignMap.tscn.
#   world_scale (Vector2): same scale used in build_county_polygons.
# Returns: void
func build_county_borders(parent: Node2D, world_scale: Vector2 = Vector2(4, 4)) -> void:
	const COUNTY_BORDER_COLOR := Color(0.10, 0.07, 0.03, 0.85)
	const COUNTY_BORDER_PX    := 1.0     # county outline target = 1 px on screen
	const DUCHY_BORDER_COLOR  := Color(0.00, 0.00, 0.00, 1.00)
	const DUCHY_BORDER_PX     := 5.5     # duchy outline target = 5.5 px on screen (5.5× county)

	var thin_pass: Array = []
	var thick_pass: Array = []

	for cn in counties:
		var co: Dictionary = counties[cn]
		var my_duchy: String = co.get("duchy", "")
		var on_duchy_edge := false
		for nb_cn in get_adjacent(cn):
			if str(counties.get(nb_cn, {}).get("duchy", "")) != my_duchy:
				on_duchy_edge = true
				break
		var target_pass: Array = thick_pass if on_duchy_edge else thin_pass
		for ring in get_polygons(cn, world_scale):
			if ring.size() >= 4:
				target_pass.append(ring)

	# Thin lines first so thick duchy lines render on top of them.
	for ring in thin_pass:
		var line := Line2D.new()
		line.points = ring
		line.closed = true
		line.default_color = COUNTY_BORDER_COLOR
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		line.set_meta("screen_px", COUNTY_BORDER_PX)
		parent.add_child(line)
	# Thick duchy lines on top of the thin ones.
	for ring in thick_pass:
		var line := Line2D.new()
		line.points = ring
		line.closed = true
		line.default_color = DUCHY_BORDER_COLOR
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		line.set_meta("screen_px", DUCHY_BORDER_PX)
		parent.add_child(line)

	print("MapData: Built %d thin + %d thick border outlines." % [thin_pass.size(), thick_pass.size()])


# Maps a duchy id to the political/geographic country its land sits in.
# Used to drive the COUNTRY-tier labels at outermost zoom.
const COUNTRY_BY_DUCHY := {
	"lancaster":  "England",
	"chester":    "England",
	"march":      "England",
	"gloucester": "England",
	"norfolk":    "England",
	"cornwall":   "England",
	"gwynedd":    "Wales",
	"deheubarth": "Wales",
	"morgannwg":  "Wales",   # geographically Welsh even though held by Marcher lords
	"highlands":  "Scotland",
	"moray":      "Scotland",
	"lothian":    "Scotland",
}


# Place country / duchy / county labels in the LabelLayer. Each label is
# tagged with its zoom band via metadata; CampaignMap.gd toggles visibility.
#
# Args:
#   parent (Node2D): typically the LabelLayer node from CampaignMap.tscn.
#   world_scale (Vector2): same scale as the polygons.
# Returns: void
func build_labels(parent: Node2D, world_scale: Vector2 = Vector2(4, 4)) -> void:
	# Per-county centroid + collected ring points so PCA can find each
	# region's principal axis. We keep the largest ring's vertices because
	# small islands distort the major-axis calculation.
	var county_centres: Dictionary = {}            # cn -> Vector2
	var county_largest_ring: Dictionary = {}       # cn -> PackedVector2Array
	for cn in counties:
		var c = counties[cn].get("center", {"x": 0, "y": 0})
		county_centres[cn] = Vector2(c["x"], c["y"]) * world_scale
		var biggest := PackedVector2Array()
		for r in get_polygons(cn, world_scale):
			if r.size() > biggest.size():
				biggest = r
		county_largest_ring[cn] = biggest

	# COUNTY LABELS — rotated to follow the long axis of the county's main ring.
	# EB Garamond serif at this tier, bumped to 52 so it stays readable when
	# zoomed in only a little past the county-band threshold.
	for cn in counties:
		var ang := _compute_label_rotation(county_largest_ring[cn])
		parent.add_child(_make_label(cn, county_centres[cn], 52, "county", ang))

	# DUCHY LABELS — centroid is the unweighted mean of member-county centres.
	# Rotation comes from PCA on those centres (so a long thin duchy gets
	# diagonal text). Duchy with a single county falls back to its county's angle.
	var duchy_points: Dictionary = {}              # did -> Array[Vector2]
	for cn in counties:
		var did = counties[cn].get("duchy", "")
		if did == "":
			continue
		var arr: Array = duchy_points.get(did, [])
		arr.append(county_centres[cn])
		duchy_points[did] = arr
	for did in duchy_points:
		var pts: Array = duchy_points[did]
		var sum := Vector2.ZERO
		for p in pts: sum += p
		var centroid := sum / float(pts.size())
		var pv := PackedVector2Array(pts)
		var ang := _compute_label_rotation(pv) if pts.size() >= 3 else 0.0
		var name: String = str(duchies.get(did, {}).get("name", did)).to_upper()
		parent.add_child(_make_label(name, centroid, 88, "duchy", ang))

	# COUNTRY LABELS — England / Scotland / Wales. Centroid is average of all
	# member-county centres. No rotation (always horizontal: these are the
	# zoomed-out anchor labels and need to read at a glance).
	var country_points: Dictionary = {}            # name -> Array[Vector2]
	for cn in counties:
		var did = counties[cn].get("duchy", "")
		var country: String = COUNTRY_BY_DUCHY.get(did, "")
		if country == "":
			continue
		var arr: Array = country_points.get(country, [])
		arr.append(county_centres[cn])
		country_points[country] = arr
	for country in country_points:
		var pts: Array = country_points[country]
		var sum := Vector2.ZERO
		for p in pts: sum += p
		var centroid := sum / float(pts.size())
		parent.add_child(_make_label(country.to_upper(), centroid, 140, "country", 0.0))

	print("MapData: Built %d labels (country+duchy+county)." % parent.get_child_count())


# Compute the rotation angle to apply to a label so its baseline follows the
# polygon's long axis. Uses the closed-form major eigenvector of the 2x2
# covariance matrix of the points around their centroid.
#
# The result is wrapped into [-π/4, π/4] so labels never appear upside-down
# or rotated more than 45° — readability over geometric fidelity.
#
# Args:
#   points (PackedVector2Array): vertices to take PCA over. Pass the largest
#       polygon ring of the region.
# Returns:
#   float: rotation in radians, in [-π/4, π/4].
func _compute_label_rotation(points: PackedVector2Array) -> float:
	var n := points.size()
	if n < 3:
		return 0.0
	var cx := 0.0
	var cy := 0.0
	for p in points:
		cx += p.x
		cy += p.y
	cx /= float(n)
	cy /= float(n)

	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	for p in points:
		var dx: float = p.x - cx
		var dy: float = p.y - cy
		sxx += dx * dx
		sxy += dx * dy
		syy += dy * dy

	# Closed-form major eigenvector angle: ½·atan2(2·Sxy, Sxx - Syy).
	# Add ε to the denom to avoid atan2(0, 0) when both are zero.
	var angle: float = 0.5 * atan2(2.0 * sxy, (sxx - syy) + 1e-9)
	# Wrap into [-π/2, π/2] (eigenvectors are ± symmetric)
	while angle >  PI * 0.5: angle -= PI
	while angle < -PI * 0.5: angle += PI
	# Clamp to a readability-safe ±45°
	return clampf(angle, -PI * 0.25, PI * 0.25)


# Helper: build one styled Label centred on world_pos, tagged with its zoom band.
# Picks the font per tier:
#   country / duchy → UnifrakturMaguntia (heavy blackletter, big headers)
#   county          → EB Garamond SemiBold (serif, much more readable at smaller sizes)
#
# Rotation is applied via pivot_offset so text rotates about its centre.
# Centring is approximate (no Label.size until in tree) but tuned for the
# font's glyph-width characteristics.
func _make_label(text: String, world_pos: Vector2, font_size: int, band: String, rotation: float = 0.0) -> Label:
	var lbl := Label.new()
	lbl.text = text

	# Pick font + per-font centring factor. Blackletter glyphs are wider than
	# serif at the same point size, so the half-width estimate differs.
	var use_blackletter: bool = (band == "country" or band == "duchy")
	var font: Font = _font_blackletter if use_blackletter else _font_serif
	var glyph_w_factor: float = 0.34 if use_blackletter else 0.27
	if font == null:
		# Lazy-load the chosen font on first request.
		if use_blackletter:
			_font_blackletter = load(FONT_PATH_BLACKLETTER)
			font = _font_blackletter
		else:
			_font_serif = load(FONT_PATH_SERIF)
			font = _font_serif
	if font != null:
		lbl.add_theme_font_override("font", font)

	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color(0.96, 0.93, 0.80))
	lbl.add_theme_color_override("font_outline_color", Color(0.04, 0.02, 0.00, 1.0))
	# Outline thickness scales with font size so big labels keep their stroke.
	lbl.add_theme_constant_override("outline_size", maxi(4, int(font_size * 0.10)))

	var est_half_w: float = font_size * glyph_w_factor * float(text.length())
	var est_half_h: float = font_size * 0.55
	lbl.position = world_pos - Vector2(est_half_w, est_half_h)
	lbl.pivot_offset = Vector2(est_half_w, est_half_h)
	lbl.rotation = rotation
	lbl.set_meta("zoom_band", band)
	return lbl


# Font paths + cached resources. Loaded on first label of each kind.
const FONT_PATH_BLACKLETTER := "res://assets/fonts/EB_Garamond,UnifrakturMaguntia/UnifrakturMaguntia/UnifrakturMaguntia-Regular.ttf"
const FONT_PATH_SERIF       := "res://assets/fonts/EB_Garamond,UnifrakturMaguntia/EB_Garamond/static/EBGaramond-SemiBold.ttf"
var _font_blackletter: Font = null
var _font_serif: Font = null
