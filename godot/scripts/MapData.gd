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

	# For each county, fill EVERY ring. Each ring is decomposed into convex
	# pieces (Geometry2D.decompose_polygon_in_convex) before being handed to
	# Polygon2D. Why: Godot's auto-triangulator silently fails on some
	# concave / coastal shapes (Orkney's mainland was the recurring offender);
	# convex pieces always render. The county-level metadata is attached to
	# the FIRST piece so click-hit-testing still works the same way.
	var county_count := 0
	var piece_count := 0
	for cn in counties:
		var co = counties[cn]
		var polys = get_polygons(cn, world_scale)
		if polys.is_empty():
			continue
		var fill_color: Color = duchy_colors.get(co.get("duchy", ""), Color(0.2, 0.2, 0.2, FILL_ALPHA))
		var first_piece_for_county := true
		for ring_idx in range(polys.size()):
			var ring: PackedVector2Array = polys[ring_idx]
			if ring.size() < 3:
				continue
			# Skip near-zero-area triangle rings — they're sub-pixel slivers
			# that just add node count without being visible.
			if ring.size() == 3:
				var a := ring[0]; var b := ring[1]; var c := ring[2]
				if abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) < 1.0:
					continue
			var convex_pieces: Array = Geometry2D.decompose_polygon_in_convex(ring)
			if convex_pieces.is_empty():
				# Fall back to the raw ring; rarely happens but better to try.
				convex_pieces = [ring]
			for piece in convex_pieces:
				if piece.size() < 3:
					continue
				var p2d := Polygon2D.new()
				p2d.name = cn.replace(" ", "_") + "_p" + str(piece_count)
				p2d.polygon = piece
				p2d.color = fill_color
				# Attach county metadata to EVERY piece so hit-testing works
				# anywhere in the county, no matter which piece is clicked.
				p2d.set_meta("county_name", cn)
				if first_piece_for_county:
					p2d.set_meta("duchy", co.get("duchy", ""))
					p2d.set_meta("earl", co.get("earl", ""))
					p2d.set_meta("income", co.get("income", 0))
					p2d.set_meta("garrison", co.get("garrison", 0))
					p2d.set_meta("population", co.get("population", 0))
					first_piece_for_county = false
				parent.add_child(p2d)
				piece_count += 1
		county_count += 1

	print("MapData: Built %d county fills as %d convex pieces." % [county_count, piece_count])


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
	# COUNTY borders: thin dark hairline around EVERY county.
	# DUCHY borders:  thicker dark line tracing the ACTUAL duchy perimeter,
	# read from the pre-computed `duchies[did].polygons` field (Python unions
	# the county polygons there). This gives correct duchy outlines —
	# internal same-duchy county edges are drawn ONLY by the thin pass.
	const COUNTY_BORDER_COLOR := Color(0.10, 0.07, 0.03, 0.85)
	const DUCHY_BORDER_COLOR  := Color(0.00, 0.00, 0.00, 1.00)   # black
	# Target screen-pixel widths come from MapSettings (adjustable + saved).
	var county_border_px: float = MapSettings.county_border_px
	var duchy_border_px:  float = MapSettings.duchy_border_px

	# Pass 1: thin county outlines
	var county_count := 0
	for cn in counties:
		for ring in get_polygons(cn, world_scale):
			if ring.size() < 4:
				continue
			var line := Line2D.new()
			line.points = ring
			line.closed = true
			line.default_color = COUNTY_BORDER_COLOR
			line.joint_mode = Line2D.LINE_JOINT_BEVEL
			line.antialiased = false
			line.set_meta("screen_px", county_border_px)
			parent.add_child(line)
			county_count += 1

	# Pass 2: thick duchy outlines, from the unioned duchy polygons.
	var duchy_count := 0
	for did in duchies:
		var d_polys: Array = duchies[did].get("polygons", [])
		for ring_raw in d_polys:
			if ring_raw.size() < 4:
				continue
			var ring := PackedVector2Array()
			for pt in ring_raw:
				ring.append(Vector2(pt[0], pt[1]) * world_scale)
			if ring.size() < 4:
				continue
			var line := Line2D.new()
			line.points = ring
			line.closed = true
			line.default_color = DUCHY_BORDER_COLOR
			line.joint_mode = Line2D.LINE_JOINT_BEVEL
			line.antialiased = false
			line.set_meta("screen_px", duchy_border_px)
			parent.add_child(line)
			duchy_count += 1

	print("MapData: Built %d county outlines + %d duchy outlines." % [county_count, duchy_count])


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

	# COUNTY LABELS — drawn as a curved per-character string that follows
	# the polygon's principal axis. Font size scales down so the label
	# always fits inside the polygon's axis extent.
	for cn in counties:
		var ring: PackedVector2Array = county_largest_ring[cn]
		var ang := _compute_label_rotation(ring)
		var max_axis: float = _axis_extent(ring, ang)
		var size_for_fit: int = _fit_font_size(cn, max_axis, 52, 18)
		parent.add_child(_make_curved_label(cn, ring, county_centres[cn], size_for_fit, "county", ang, max_axis))

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


# Return the polygon's extent along the axis given by `angle`. Equivalent to
# (max projection − min projection) of the points onto the unit vector
# (cos angle, sin angle).
#
# Args:
#   points (PackedVector2Array): polygon vertices.
#   angle (float): axis angle in radians.
# Returns:
#   float: extent in world units. 0 if fewer than 2 points.
func _axis_extent(points: PackedVector2Array, angle: float) -> float:
	if points.size() < 2:
		return 0.0
	var dir := Vector2(cos(angle), sin(angle))
	var lo: float = INF
	var hi: float = -INF
	for p in points:
		var t: float = p.dot(dir)
		if t < lo: lo = t
		if t > hi: hi = t
	return hi - lo


# Pick a font size such that the rendered label fits within `max_axis` world
# units along the principal axis. Margin is built in so the text doesn't
# kiss the polygon edges.
#
# Args:
#   text (String): the label string.
#   max_axis (float): polygon extent along the label's rotation axis.
#   nominal (int): preferred (max) font size if the polygon is large enough.
#   minimum (int): floor — never go below this even if the polygon is tiny.
# Returns:
#   int: chosen font size in points.
func _fit_font_size(text: String, max_axis: float, nominal: int, minimum: int) -> int:
	if text.length() == 0 or max_axis <= 0.0:
		return nominal
	# Same factor used in _make_label (Garamond glyph half-width per pt).
	const W_FACTOR := 0.27
	const SAFETY := 0.80    # only use 80% of the polygon's axis extent
	var allowed_width: float = max_axis * SAFETY
	var fit: int = int(allowed_width / (W_FACTOR * float(text.length()) * 2.0))
	return clampi(fit, minimum, nominal)


# Helper: build one styled Label centred on world_pos, tagged with its zoom band.
# All tiers now use EB Garamond SemiBold (the heavy blackletter was killing
# legibility at small sizes per user feedback).
#
# Rotation is applied via pivot_offset so text rotates about its centre.
func _make_label(text: String, world_pos: Vector2, font_size: int, band: String, rotation: float = 0.0) -> Label:
	var lbl := Label.new()
	lbl.text = text

	if _font_serif == null:
		_font_serif = load(FONT_PATH_SERIF)
	if _font_serif != null:
		lbl.add_theme_font_override("font", _font_serif)

	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color(0.96, 0.93, 0.80))
	lbl.add_theme_color_override("font_outline_color", Color(0.04, 0.02, 0.00, 1.0))
	lbl.add_theme_constant_override("outline_size", maxi(3, int(font_size * 0.09)))

	# Garamond glyph-width factor (much narrower than blackletter).
	var est_half_w: float = font_size * 0.27 * float(text.length())
	var est_half_h: float = font_size * 0.55
	lbl.position = world_pos - Vector2(est_half_w, est_half_h)
	lbl.pivot_offset = Vector2(est_half_w, est_half_h)
	lbl.rotation = rotation
	lbl.set_meta("zoom_band", band)
	return lbl


# EB Garamond SemiBold for every tier.
const FONT_PATH_SERIF := "res://assets/fonts/EB_Garamond,UnifrakturMaguntia/EB_Garamond/static/EBGaramond-SemiBold.ttf"
var _font_serif: Font = null


# Build a curved label: each character is a separate Label placed along a
# quadratic bezier whose endpoints sit at the polygon's principal-axis
# extents and whose middle control point is offset perpendicular by the
# centerline-bend of the polygon. The returned Node2D is tagged with the
# zoom band so CampaignMap's LOD switch still finds it.
#
# Args:
#   text (String): the label text (e.g. "Yorkshire").
#   ring (PackedVector2Array): polygon's largest ring (world coords).
#   centre (Vector2): polygon centroid in world coords.
#   font_size (int): pre-fitted point size for this label.
#   band (String): "county" / "duchy" / "country" — drives visibility.
#   axis_angle (float): radians, principal-axis direction.
#   axis_length (float): polygon extent along axis in world units.
# Returns:
#   Node2D: container holding one Label per character.
func _make_curved_label(text: String, ring: PackedVector2Array, centre: Vector2,
		font_size: int, band: String, axis_angle: float, axis_length: float) -> Node2D:
	var container := Node2D.new()
	container.set_meta("zoom_band", band)
	if text.length() == 0 or axis_length <= 0.0:
		return container

	# Build bezier control points.
	var dir := Vector2(cos(axis_angle), sin(axis_angle))
	var perp := Vector2(-dir.y, dir.x)
	# Use 70% of the axis for text so the label doesn't hug the polygon edge.
	var half_len: float = axis_length * 0.35
	var p0: Vector2 = centre - dir * half_len
	var p2: Vector2 = centre + dir * half_len
	# Centerline bend at axis midpoint, capped so the curve never gets goofy.
	var bend: float = _centerline_bend(ring, centre, dir, perp)
	bend = clampf(bend, -axis_length * 0.20, axis_length * 0.20)
	# Quadratic bezier passes through (P0 + 2P1 + P2)/4 at t=0.5; with
	# (P0 + P2)/2 = centre, requiring the midpoint of the curve to land at
	# centre + perp*bend gives P1 = centre + perp*(2*bend).
	var p1: Vector2 = centre + perp * (bend * 2.0)

	# Ensure the font resource is loaded once.
	if _font_serif == null:
		_font_serif = load(FONT_PATH_SERIF)

	# Approximate per-character pen advance, used for spacing along the curve.
	# For Garamond SemiBold this is roughly 0.50 of the font size for caps,
	# 0.42 for mixed case. We use 0.46 as a workable average.
	var char_pen: float = font_size * 0.46
	# Approximate the bezier's arc length by sampling — proper integration
	# would be overkill for label placement.
	var arc_len: float = _bezier_approx_length(p0, p1, p2, 16)
	# How much of the curve do we actually want to use? Just enough for the
	# text width, centred on t=0.5.
	var text_width: float = char_pen * float(text.length() - 1)
	var coverage: float = clampf(text_width / max(arc_len, 1.0), 0.05, 1.0)
	var t_start: float = 0.5 - coverage * 0.5
	var t_step: float = (coverage) / max(1.0, float(text.length() - 1))

	var half_w_char: float = font_size * 0.27
	var half_h_char: float = font_size * 0.55

	for i in range(text.length()):
		var ch: String = text.substr(i, 1)
		if ch == " ":
			continue
		var t: float = t_start + t_step * float(i) if text.length() > 1 else 0.5
		var pos: Vector2 = _bez(p0, p1, p2, t)
		var tan: Vector2 = _bez_tangent(p0, p1, p2, t)
		var angle: float = atan2(tan.y, tan.x)
		# Wrap to readable range so chars never appear upside-down.
		while angle >  PI * 0.5: angle -= PI
		while angle < -PI * 0.5: angle += PI

		var lbl := Label.new()
		lbl.text = ch
		lbl.add_theme_font_override("font", _font_serif)
		lbl.add_theme_font_size_override("font_size", font_size)
		lbl.add_theme_color_override("font_color", Color(0.96, 0.93, 0.80))
		lbl.add_theme_color_override("font_outline_color", Color(0.04, 0.02, 0.00, 1.0))
		lbl.add_theme_constant_override("outline_size", maxi(3, int(font_size * 0.09)))
		lbl.position = pos - Vector2(half_w_char, half_h_char)
		lbl.pivot_offset = Vector2(half_w_char, half_h_char)
		lbl.rotation = angle
		container.add_child(lbl)
	return container


# Quadratic bezier evaluation: (1-t)²·P0 + 2(1-t)t·P1 + t²·P2.
func _bez(p0: Vector2, p1: Vector2, p2: Vector2, t: float) -> Vector2:
	var omt: float = 1.0 - t
	return omt * omt * p0 + 2.0 * omt * t * p1 + t * t * p2


# Derivative of the bezier wrt t — gives the tangent vector at parameter t.
func _bez_tangent(p0: Vector2, p1: Vector2, p2: Vector2, t: float) -> Vector2:
	return 2.0 * ((1.0 - t) * (p1 - p0) + t * (p2 - p1))


# Approximate arc length by polyline sampling. `samples` chord count.
func _bezier_approx_length(p0: Vector2, p1: Vector2, p2: Vector2, samples: int) -> float:
	var total: float = 0.0
	var prev: Vector2 = p0
	for i in range(1, samples + 1):
		var t: float = float(i) / float(samples)
		var pt: Vector2 = _bez(p0, p1, p2, t)
		total += prev.distance_to(pt)
		prev = pt
	return total


# Returns the polygon's centerline perpendicular offset at the MIDPOINT of
# its principal axis. Vertices in the middle ±15% axis band are sampled,
# and the midpoint between their min and max perpendicular coordinates is
# returned. Symmetric polygons → 0. Banana-shaped ones → non-zero bend.
func _centerline_bend(ring: PackedVector2Array, centre: Vector2, dir: Vector2, perp: Vector2) -> float:
	if ring.size() < 5:
		return 0.0
	var min_u: float = INF
	var max_u: float = -INF
	for p in ring:
		var u: float = (p - centre).dot(dir)
		if u < min_u: min_u = u
		if u > max_u: max_u = u
	var axis_len: float = max_u - min_u
	if axis_len < 4.0:
		return 0.0
	var bin_lo: float = min_u + axis_len * 0.35
	var bin_hi: float = min_u + axis_len * 0.65
	var v_lo: float = INF
	var v_hi: float = -INF
	for p in ring:
		var u: float = (p - centre).dot(dir)
		if u >= bin_lo and u <= bin_hi:
			var v: float = (p - centre).dot(perp)
			if v < v_lo: v_lo = v
			if v > v_hi: v_hi = v
	if v_lo == INF:
		return 0.0
	return (v_lo + v_hi) * 0.5
