extends Node2D

@onready var county_layer: Node2D = $CountyLayer
@onready var border_layer: Node2D = $BorderLayer
@onready var label_layer: Node2D = $LabelLayer
@onready var camera: Camera2D = $Camera2D
@onready var ui: CanvasLayer = $UI

# Zoom thresholds for the label LOD system.
#   z < ZOOM_DUCHY_MAX        → only DUCHY-tier labels visible
#   ZOOM_DUCHY_MAX..ZOOM_FIEF → only COUNTY-tier labels visible
#   z >= ZOOM_FIEF            → (future) fief/city labels visible
const ZOOM_DUCHY_MAX := 0.22
const ZOOM_FIEF := 1.5

# Tint applied to all Polygon2D nodes that share the currently-selected county
# name. Multiplied with their base colour, so values >1 brighten.
const SELECTED_TINT := Color(1.45, 1.25, 0.85)
const NORMAL_TINT := Color.WHITE

# Camera tunables.
const ZOOM_STEP := 1.15            # multiplicative factor per wheel notch
const ZOOM_MIN  := 0.03            # most zoomed-out allowed (whole island visible)
const ZOOM_MAX  := 4.0             # most zoomed-in allowed (single barony)
const PAN_KEY_PIXELS_PER_SEC := 800.0  # WASD/arrow speed measured in SCREEN pixels

# Distance in screen pixels a left-mouse press must move before we treat it
# as a drag (and pan the camera) rather than a click (and select a county).
const CLICK_DRAG_THRESHOLD := 5.0

# Width of the right-hand InfoPanel — subtract from horizontal viewport when
# computing fit-to-screen so the map isn't half-hidden behind the panel.
const UI_PANEL_WIDTH := 320.0

# Tracks the currently-selected county by its data-layer name (e.g. "Yorkshire"),
# not by Polygon2D node, because a single county can be drawn as several polygons
# (mainland + islands). Empty string means no selection.
var _selected_county_name: String = ""

# Middle-mouse-drag state.
var _is_panning: bool = false

# Left-mouse press/drag state — used to differentiate a click (select) from a
# drag (pan). Set on press, mutated on motion, read on release.
var _left_press_pos: Vector2 = Vector2.ZERO
var _left_dragged: bool = false

# Cache of last-applied zoom-band so the label visibility refresh only fires
# when the zoom crosses a threshold. -1 = uninitialised.
#   0 = duchy band, 1 = county band, 2 = fief band
var _last_zoom_band: int = -1

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
		push_error("MapData failed to load — check res://data/bg_godot.json")
		return
	
	print("Building polygons...")
	MapData.build_county_polygons(county_layer, Vector2(4, 4))
	MapData.build_county_borders(border_layer, Vector2(4, 4))
	MapData.build_labels(label_layer, Vector2(4, 4))

	var polygon_count = 0
	for child in county_layer.get_children():
		if child is Polygon2D:
			polygon_count += 1

	print("Polygons created: %d" % polygon_count)

	camera.enabled = true
	camera.make_current()
	fit_to_bounds()
	_update_label_visibility()
	print("Camera: position=%v, zoom=%v" % [camera.position, camera.zoom])
	print("=== build_map() END ===")


# Update Label visibility based on the camera's current zoom. Only iterates
# children when the zoom band changes (cheap to call every frame).
#
# Returns: void
func _update_label_visibility() -> void:
	var z := camera.zoom.x
	var band: int
	if z < ZOOM_DUCHY_MAX:
		band = 0
	elif z < ZOOM_FIEF:
		band = 1
	else:
		band = 2
	if band == _last_zoom_band:
		return
	_last_zoom_band = band
	var want_duchy := (band == 0)
	var want_county := (band == 1)
	for child in label_layer.get_children():
		var t := str(child.get_meta("zoom_band", ""))
		if t == "duchy":
			child.visible = want_duchy
		elif t == "county":
			child.visible = want_county


# Frame the camera on the full polygon bounding box, leaving room on the
# right for the InfoPanel. Bound to the F key in _unhandled_input.
#
# Returns: void
func fit_to_bounds() -> void:
	var bbox := _compute_polygons_bbox()
	if bbox.size == Vector2.ZERO:
		# Fallback: hard-coded centre, used if polygons haven't been built yet.
		camera.position = Vector2(1500, 170)
		camera.zoom = Vector2(0.08, 0.08)
		return
	# Shift the focal point right so the geographic centre sits in the middle of
	# the MAP area (viewport minus the panel), not the middle of the full window.
	var vp_w: float = ProjectSettings.get_setting("display/window/size/viewport_width", 2300)
	var vp_h: float = ProjectSettings.get_setting("display/window/size/viewport_height", 1440)
	var map_w := vp_w - UI_PANEL_WIDTH
	# 10% margin so the map doesn't kiss the edges.
	var zx := map_w / (bbox.size.x * 1.1)
	var zy := vp_h  / (bbox.size.y * 1.1)
	var z := minf(zx, zy)
	camera.zoom = Vector2(z, z)
	# Camera2D centres its position at the FULL viewport centre. The InfoPanel
	# covers the right UI_PANEL_WIDTH pixels, so the "map area" centre is offset
	# LEFT of the viewport centre by half the panel width. To make the bbox
	# centre appear in the middle of the map area, the camera position must
	# sit half-a-panel-width to the RIGHT of the bbox centre (in world units).
	var centre := bbox.get_center()
	centre.x += (UI_PANEL_WIDTH * 0.5) / z
	camera.position = centre

# ── INPUT ─────────────────────────────────────────────────────────────────────

# Engine-invoked input callback. We use _unhandled_input (not _input) so that
# clicks consumed by Control nodes in $UI never reach the map.
#
# Bindings:
#   Left click (no drag)     → select county under cursor
#   Left click + drag        → pan camera (drag threshold = CLICK_DRAG_THRESHOLD px)
#   Middle button press/drag → pan camera (alternate)
#   Mouse wheel              → zoom in/out at cursor
#   Escape                   → clear selection
#   F                        → fit-to-bounds (refit whole map)
#
# Args:
#   event (InputEvent): Any input event from the engine.
# Returns: void
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_left_press_pos = mb.position
					_left_dragged = false
				else:
					# Release. If we never crossed the drag threshold, treat as
					# a click and select the county under the cursor. Empty-
					# space clicks do NOT clear — use Escape for that.
					if not _left_dragged:
						var hit := _county_polygon_at(get_global_mouse_position())
						if hit:
							_select_county(hit.get_meta("county_name", ""))
			MOUSE_BUTTON_MIDDLE:
				_is_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom_at_cursor(ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom_at_cursor(1.0 / ZOOM_STEP)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# Left-mouse-drag pan: promote a held left-button to "dragging" once
		# motion exceeds the click threshold, then pan on subsequent motion.
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if not _left_dragged:
				if mm.position.distance_to(_left_press_pos) > CLICK_DRAG_THRESHOLD:
					_left_dragged = true
			if _left_dragged:
				camera.position -= mm.relative / camera.zoom
		elif _is_panning:
			camera.position -= mm.relative / camera.zoom
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_ESCAPE:
				_clear_selection()
			KEY_F:
				fit_to_bounds()


# Engine-invoked per frame. Reads keyboard pan input (WASD or arrows) and
# nudges the camera. Pan speed is constant in SCREEN pixels so it feels the
# same regardless of zoom level.
#
# Args:
#   delta (float): Seconds since last frame.
# Returns: void
func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):  dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):    dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):  dir.y += 1.0
	if dir != Vector2.ZERO:
		camera.position += dir.normalized() * PAN_KEY_PIXELS_PER_SEC * delta / camera.zoom
	_update_label_visibility()


# Zoom toward (or away from) the world point currently under the mouse cursor.
# Works by recording the world-space mouse position before the zoom change,
# applying the zoom, then shifting the camera so the same world point lands
# under the cursor afterwards.
#
# Args:
#   factor (float): Multiplicative zoom change. >1 zooms in, <1 zooms out.
# Returns: void
func _zoom_at_cursor(factor: float) -> void:
	var mouse_world_before := get_global_mouse_position()
	var new_zoom: float = clampf(camera.zoom.x * factor, ZOOM_MIN, ZOOM_MAX)
	camera.zoom = Vector2(new_zoom, new_zoom)
	var mouse_world_after := get_global_mouse_position()
	camera.position += mouse_world_before - mouse_world_after


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
