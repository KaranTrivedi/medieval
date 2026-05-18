extends Node2D

@onready var county_layer: Node2D = $CountyLayer
@onready var camera: Camera2D = $Camera2D
@onready var ui: CanvasLayer = $UI

# Tint applied to all Polygon2D nodes that share the currently-selected county
# name. Multiplied with their base colour, so values >1 brighten.
const SELECTED_TINT := Color(1.45, 1.25, 0.85)
const NORMAL_TINT := Color.WHITE

# Tracks the currently-selected county by its data-layer name (e.g. "Yorkshire"),
# not by Polygon2D node, because a single county can be drawn as several polygons
# (mainland + islands). Empty string means no selection.
var _selected_county_name: String = ""

func _ready():
	print("=== _ready() START ===")
	if MapData.is_loaded:
		build_map()
	else:
		print("MapData not loaded yet — waiting for map_loaded signal")
		MapData.map_loaded.connect(build_map, CONNECT_ONE_SHOT)
	print("=== _ready() END ===")

func build_map():
	print("=== build_map() START ===")
	print("County layer has %d children" % county_layer.get_child_count())

	if not MapData.is_loaded:
		push_error("MapData failed to load — check res://data/england_godot.json")
		return
	
	print("Building polygons...")
	MapData.build_county_polygons(county_layer, Vector2(4, 4))
	
	var polygon_count = 0
	for child in county_layer.get_children():
		if child is Polygon2D:
			polygon_count += 1
	
	print("Polygons created: %d" % polygon_count)
	
	# Setup camera — frame the polygons' actual bounding box.
	# Polygon world coords (after Vector2(4,4) scale) span roughly
	# X: -900..3880, Y: -4340..4690 — geographic centre around (1500, 170).
	camera.enabled = true
	camera.make_current()
	var bbox := _compute_polygons_bbox()
	if bbox.size != Vector2.ZERO:
		camera.position = bbox.get_center()
		# Use the PROJECT's configured viewport size, not get_viewport_rect().
		# During _ready() the runtime viewport may report 0 or a default that
		# produces a microscopic zoom (~0.006) — which looks like a grey screen.
		var vp_w: float = ProjectSettings.get_setting("display/window/size/viewport_width", 1152)
		var vp_h: float = ProjectSettings.get_setting("display/window/size/viewport_height", 648)
		var zx := vp_w / (bbox.size.x * 1.1)
		var zy := vp_h / (bbox.size.y * 1.1)
		var z := minf(zx, zy)
		camera.zoom = Vector2(z, z)
	else:
		camera.position = Vector2(1500, 170)
		camera.zoom = Vector2(0.08, 0.08)

	print("Camera: position=%v, zoom=%v" % [camera.position, camera.zoom])
	print("=== build_map() END ===")

# ── INPUT ─────────────────────────────────────────────────────────────────────

# Engine-invoked input callback. We use _unhandled_input (not _input) so that
# clicks consumed by Control nodes in $UI never reach the map.
#
# Args:
#   event (InputEvent): Anything the engine sends — we only act on a left
#       mouse button PRESS. Right-click clears selection.
# Returns:
#   void
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		var world_pos := get_global_mouse_position()
		var hit := _county_polygon_at(world_pos)
		if hit:
			_select_county(hit.get_meta("county_name", ""))
		else:
			_clear_selection()
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		_clear_selection()


# Find the topmost Polygon2D under a world-space point.
# Iterates children in reverse draw order (last child is rendered on top) so
# islands or fragments drawn above a larger polygon win.
#
# Args:
#   world_pos (Vector2): Point in the CountyLayer coordinate space, i.e. the
#       same space the polygon vertices live in.
# Returns:
#   Polygon2D: The hit polygon, or null if the point is outside every county.
func _county_polygon_at(world_pos: Vector2) -> Polygon2D:
	var children := county_layer.get_children()
	for i in range(children.size() - 1, -1, -1):
		var child := children[i]
		if child is Polygon2D:
			var poly: Polygon2D = child
			if Geometry2D.is_point_in_polygon(world_pos, poly.polygon):
				return poly
	return null


# Mark a county as selected: update highlight on every Polygon2D fragment with
# that meta name, and push the county's data into the InfoPanel.
#
# Args:
#   county_name (String): Key into MapData.counties (e.g. "Yorkshire"). An
#       empty string is treated as a clear.
# Returns:
#   void
func _select_county(county_name: String) -> void:
	if county_name == "":
		_clear_selection()
		return
	if county_name == _selected_county_name:
		return  # idempotent — clicking the same county twice does nothing
	_tint_county(_selected_county_name, NORMAL_TINT)
	_selected_county_name = county_name
	_tint_county(county_name, SELECTED_TINT)

	# Pull a copy of the county record so we can pass it to the UI without
	# leaking the live dictionary reference held by MapData.
	var data: Dictionary = MapData.get_county(county_name).duplicate()
	ui.update_panel(data, county_name)


# Reset the current selection and clear the InfoPanel back to placeholders.
#
# Returns:
#   void
func _clear_selection() -> void:
	if _selected_county_name == "":
		return
	_tint_county(_selected_county_name, NORMAL_TINT)
	_selected_county_name = ""
	if ui.has_method("clear_panel"):
		ui.clear_panel()


# Apply a modulate tint to every Polygon2D whose "county_name" meta matches.
# A county can be represented by several polygons (mainland + islands), so we
# iterate the whole CountyLayer rather than tracking individual nodes.
#
# Args:
#   county_name (String): Meta value to match against. Empty string is a no-op.
#   tint (Color): Modulate colour to apply. Use NORMAL_TINT to clear.
# Returns:
#   void
func _tint_county(county_name: String, tint: Color) -> void:
	if county_name == "":
		return
	for child in county_layer.get_children():
		if child is Polygon2D and child.get_meta("county_name", "") == county_name:
			child.modulate = tint


func _compute_polygons_bbox() -> Rect2:
	var has_any := false
	var rect := Rect2()
	for child in county_layer.get_children():
		if child is Polygon2D and child.polygon.size() > 0:
			for p in child.polygon:
				if not has_any:
					rect = Rect2(p, Vector2.ZERO)
					has_any = true
				else:
					rect = rect.expand(p)
	return rect
