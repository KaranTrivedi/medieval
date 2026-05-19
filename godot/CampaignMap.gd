extends Node2D

@onready var county_layer: Node2D = $CountyLayer
@onready var border_layer: Node2D = $BorderLayer
@onready var label_layer: Node2D = $LabelLayer
@onready var camera: Camera2D = $Camera2D
@onready var ui: CanvasLayer = $UI
@onready var settings_panel: Panel = $UI/Control/SettingsPanel
@onready var tooltip: Panel = $UI/Control/Tooltip
@onready var tooltip_label: Label = $UI/Control/Tooltip/Label

const WORLD_SCALE := Vector2(4, 4)

# Zoom thresholds for the label LOD system come from the MapSettings
# autoload — adjustable at runtime via the Settings panel and persisted to
# user://map_settings.cfg. See MapSettings.gd for defaults.

# Tint applied to all Polygon2D nodes that share the currently-selected county
# name. Multiplied with their base colour, so values >1 brighten.
const SELECTED_TINT := Color(1.45, 1.25, 0.85)
const NORMAL_TINT := Color.WHITE

# Barony outlines are dark + thin — a modulate-style tint isn't visible on
# them. So we swap the line colour directly to bright yellow, AND fatten
# their on-screen width via the screen_px meta that _update_border_widths
# reads. Originals stored as "base_color" + "base_screen_px" metas.
const SELECTED_BARONY_COLOR := Color(1.0, 0.92, 0.0, 1.0)
const SELECTED_BARONY_PX_MULT := 3.5     # 3.5× the normal hairline width

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

# Currently-selected region type: "country" / "duchy" / "county" / "barony" / "".
# Drives the InfoPanel render and the clear-selection logic.
var _selected_type: String = ""
# Per-tier IDs for the active selection — only one is non-empty at a time.
var _selected_country: String = ""
var _selected_duchy: String = ""
var _selected_barony: String = ""

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

# Last zoom value at which we rescaled Line2D widths. We only rescale when the
# zoom changes by more than a small relative threshold to avoid touching ~600
# Line2D nodes every single frame for sub-pixel jitter.
var _last_border_zoom: float = -1.0
const BORDER_RESCALE_REL := 0.02   # 2% zoom delta triggers a rescale

func _ready():
	print("=== _ready() START ===")
	# Listen for slider-driven settings changes so labels + borders re-snap
	# to the new thresholds without needing a manual refresh.
	MapSettings.changed.connect(_on_map_settings_changed)
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
		push_error("MapData failed to load — check res://data/gb_godot.json")
		return
	
	print("Building polygons...")
	MapData.build_county_polygons(county_layer, Vector2(4, 4))
	MapData.build_county_borders(border_layer, Vector2(4, 4))
	MapData.build_baronies(border_layer, label_layer, Vector2(4, 4))
	MapData.build_labels(label_layer, Vector2(4, 4))

	# Quick scene-tree audit so the build summary actually reflects everything
	# (county fills + barony outlines, both dashed and solid).
	var fill_count := 0
	for child in county_layer.get_children():
		if child is Polygon2D:
			fill_count += 1
	var border_solid := 0
	var border_dashed := 0
	for child in border_layer.get_children():
		if child is Line2D:
			border_solid += 1
		elif child.has_method("queue_redraw"):  # DashedPolygon
			border_dashed += 1
	print("Scene built: %d fills, %d solid lines, %d dashed barony lines, %d label nodes." % [
		fill_count, border_solid, border_dashed, label_layer.get_child_count()
	])

	camera.enabled = true
	camera.make_current()
	fit_to_bounds()
	_update_label_visibility()
	_update_border_widths()
	print("Camera: position=%v, zoom=%v" % [camera.position, camera.zoom])
	print("=== build_map() END ===")


# Rescale every Line2D in BorderLayer so its width measured in SCREEN pixels
# matches the per-line target stored in meta("screen_px"). Line2D.width is in
# world units, so we convert: world_width = screen_px / camera.zoom.
#
# Skipped when zoom hasn't changed enough to matter — avoids touching ~600
# Line2D nodes every frame for sub-pixel jitter.
#
# Returns: void
func _update_border_widths() -> void:
	var z: float = camera.zoom.x
	if z <= 0.0:
		return
	if _last_border_zoom > 0.0:
		var rel: float = abs(z - _last_border_zoom) / _last_border_zoom
		if rel < BORDER_RESCALE_REL:
			return
	_last_border_zoom = z
	for child in border_layer.get_children():
		if child is Line2D:
			var target_px: float = float(child.get_meta("screen_px", 1.0))
			(child as Line2D).width = target_px / z
		elif child.has_method("refresh"):
			# DashedPolygon recomputes its world-unit width on its own at
			# draw time using camera zoom; we just need to ask it to redraw.
			child.refresh()


# Update Label visibility based on camera zoom. Only iterates children when
# the zoom crosses a band threshold (cheap to call every frame).
#
# Bands:
#   0 = country, 1 = duchy, 2 = county, 3 = fief
#
# Thresholds come from MapSettings so the Settings panel can move them live.
#
# Returns: void
func _update_label_visibility() -> void:
	var z := camera.zoom.x
	var band: int
	if z < MapSettings.country_zoom_max:
		band = 0
	elif z < MapSettings.duchy_zoom_max:
		band = 1
	elif z < MapSettings.county_zoom_max:
		band = 2
	else:
		band = 3
	if band == _last_zoom_band:
		return
	# Band crossed — what the player can select just changed, so any current
	# selection no longer makes sense. Clear it (drops tint + hides panel).
	# Skip on first build (_last_zoom_band == -1 sentinel).
	if _last_zoom_band != -1:
		_clear_selection()
		# Re-evaluate the tooltip too: the same world point now maps to a
		# different tier.
		_update_tooltip(get_viewport().get_mouse_position(), get_global_mouse_position())
	_last_zoom_band = band
	var want_country := (band == 0)
	var want_duchy   := (band == 1)
	var want_county  := (band == 2)
	var want_barony  := (band == 3)
	for child in label_layer.get_children():
		var t := str(child.get_meta("zoom_band", ""))
		match t:
			"country": child.visible = want_country
			"duchy":   child.visible = want_duchy
			"county":  child.visible = want_county
			"barony":  child.visible = want_barony
	# BorderLayer hosts solid barony lines ("barony") at deep-zoom, plus
	# dashed barony hints ("barony_dashed") that appear one tier earlier
	# (county band). Everything else stays visible.
	for child in border_layer.get_children():
		var tb := str(child.get_meta("zoom_band", ""))
		match tb:
			"barony":         child.visible = want_barony
			"barony_dashed":  child.visible = want_county


# Called when MapSettings emits `changed`. Force-refresh visibility and
# border widths without waiting for a zoom delta to trigger them.
func _on_map_settings_changed() -> void:
	_last_zoom_band = -1
	_last_border_zoom = -1.0
	_update_label_visibility()
	_update_border_widths()
	#build_map()


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
					# Release. If we never crossed the drag threshold, treat
					# as a click. Hit on a county → select it. Empty space
					# (and Escape) both clear the current selection.
					if not _left_dragged:
						var hit := _hit_test_at_band(get_global_mouse_position())
						if hit.is_empty():
							_clear_selection()
						else:
							_dispatch_selection(hit)
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
				_hide_tooltip()
		elif _is_panning:
			camera.position -= mm.relative / camera.zoom
			_hide_tooltip()
		else:
			_update_tooltip(mm.position, get_global_mouse_position())
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_ESCAPE:
				_clear_selection()
			KEY_F:
				fit_to_bounds()
			KEY_O:
				if settings_panel:
					settings_panel.visible = not settings_panel.visible


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
	_update_border_widths()


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
	# Tooltip's tier depends on zoom — refresh even though the mouse hasn't
	# moved on screen. _update_label_visibility on the next frame will also
	# reset the selection if the band crossed a threshold.
	_update_tooltip(get_viewport().get_mouse_position(), get_global_mouse_position())


# Find the topmost Polygon2D under a world-space point.
# Iterates children in reverse draw order (last child is rendered on top) so
# islands or fragments drawn above a larger polygon win.
#
# Args:
#   world_pos (Vector2): Point in the CountyLayer coordinate space, i.e. the
#       same space the polygon vertices live in.
# Returns:
#   Polygon2D: The hit polygon, or null if the point is outside every county.
# Hit-test at the current zoom band. Returns a dict describing what was
# clicked, dispatched by which label LOD tier is active:
#   { "type": "country"|"duchy"|"county"|"barony", "id": String, "name": String,
#     "county": String (for barony only) }
# Empty {} when nothing was hit.
func _hit_test_at_band(world_pos: Vector2) -> Dictionary:
	var z: float = camera.zoom.x
	# At BARONY band, test baronies first; fall back to county if no barony
	# polygon contains the cursor (e.g. clicking the sea inside a county bbox).
	if z >= MapSettings.county_zoom_max:
		var b: Dictionary = MapData.barony_at(world_pos, WORLD_SCALE)
		if not b.is_empty():
			return {"type": "barony", "id": b.get("id", ""),
					"name": b.get("name", ""), "county": b.get("county", "")}
	# County polygon is the universal anchor — used for the COUNTY tier
	# and as the lookup-key for the DUCHY / COUNTRY tiers.
	var poly: Polygon2D = _county_polygon_at(world_pos)
	if poly == null:
		return {}
	var cn: String = str(poly.get_meta("county_name", ""))
	if cn == "":
		return {}
	if z < MapSettings.country_zoom_max:
		var d: String = str(MapData.counties.get(cn, {}).get("duchy", ""))
		var country: String = MapData.COUNTRY_BY_DUCHY.get(d, "")
		if country == "":
			return {}
		return {"type": "country", "id": country, "name": country}
	if z < MapSettings.duchy_zoom_max:
		var d2: String = str(MapData.counties.get(cn, {}).get("duchy", ""))
		var dname: String = str(MapData.duchies.get(d2, {}).get("name", d2))
		return {"type": "duchy", "id": d2, "name": dname}
	# COUNTY band — and the BARONY fallback path also lands here.
	return {"type": "county", "id": cn, "name": cn}


# Route a hit to the right selector + InfoPanel update.
func _dispatch_selection(hit: Dictionary) -> void:
	match str(hit.get("type", "")):
		"country": _select_country(hit)
		"duchy":   _select_duchy(hit)
		"county":  _select_county(str(hit.get("id", "")))
		"barony":  _select_barony(hit)


# Show + populate the InfoPanel for a country-tier selection. Tints every
# county whose duchy maps to this country.
func _select_country(hit: Dictionary) -> void:
	_clear_selection_tint()
	_selected_type = "country"
	_selected_county_name = ""
	_selected_country = str(hit.get("id", ""))
	for cn in MapData.counties:
		var d: String = str(MapData.counties[cn].get("duchy", ""))
		if MapData.COUNTRY_BY_DUCHY.get(d, "") == _selected_country:
			_tint_county(cn, SELECTED_TINT)
	var stats: Dictionary = MapData.aggregate_country(_selected_country)
	stats["type"] = "country"
	stats["name"] = hit.get("name", "")
	ui.update_panel_typed(stats)


# Show + populate the InfoPanel for a duchy-tier selection. Tints all
# counties of that duchy so the user sees the duchy as a coloured group.
func _select_duchy(hit: Dictionary) -> void:
	_clear_selection_tint()
	_selected_type = "duchy"
	_selected_county_name = ""
	_selected_duchy = str(hit.get("id", ""))
	for cn in MapData.counties:
		if str(MapData.counties[cn].get("duchy", "")) == _selected_duchy:
			_tint_county(cn, SELECTED_TINT)
	var lord: String = str(MapData.duchies.get(_selected_duchy, {}).get("lord", ""))
	var stats: Dictionary = MapData.aggregate_duchy(_selected_duchy)
	stats["type"] = "duchy"
	stats["name"] = hit.get("name", "")
	stats["lord"] = lord
	ui.update_panel_typed(stats)


# Show + populate the InfoPanel for a barony-tier selection. Tints the
# barony's own outline (both solid and dashed versions, matched via the
# "barony_id" meta tag on each Line2D / DashedPolygon).
func _select_barony(hit: Dictionary) -> void:
	_clear_selection_tint()
	_selected_type = "barony"
	_selected_county_name = ""
	_selected_barony = str(hit.get("id", ""))
	# Swap colour + bump screen_px so the highlight reads from across the
	# screen, not just on the line where the cursor was.
	var zoom: float = camera.zoom.x
	for child in border_layer.get_children():
		if str(child.get_meta("barony_id", "")) != _selected_barony:
			continue
		var base_px: float = float(child.get_meta("screen_px", 1.4))
		child.set_meta("base_screen_px", base_px)
		var new_px: float = base_px * SELECTED_BARONY_PX_MULT
		child.set_meta("screen_px", new_px)
		if child is Line2D:
			var line: Line2D = child
			line.default_color = SELECTED_BARONY_COLOR
			line.width = new_px / max(zoom, 0.0001)
		elif child.has_method("queue_redraw"):  # DashedPolygon
			child.screen_px = new_px
			child.color = SELECTED_BARONY_COLOR
			child.queue_redraw()
	# Also tint the parent county for additional visual context.
	var parent_county: String = str(hit.get("county", ""))
	if parent_county != "":
		_tint_county(parent_county, Color(1.15, 1.10, 0.95))
	# Aggregate barony economy from the parent county's pro-rata share so
	# we have something meaningful to display until per-barony data lands.
	var stats: Dictionary = MapData.aggregate_barony(parent_county, _selected_barony)
	stats["type"] = "barony"
	stats["name"] = hit.get("name", "")
	stats["county"] = parent_county
	stats["id"] = _selected_barony
	ui.update_panel_typed(stats)


# Reset whatever tinting is currently applied without touching state vars.
# Used at the top of each new select_* to undo the previous selection's tint.
func _clear_selection_tint() -> void:
	match _selected_type:
		"county":
			if _selected_county_name != "":
				_tint_county(_selected_county_name, NORMAL_TINT)
		"duchy", "country":
			# Both tiers tint a set of counties — easier to reset all than track which.
			for cn in MapData.counties:
				_tint_county(cn, NORMAL_TINT)
		"barony":
			# Restore each outline's base colour + screen_px (both stashed
			# as meta at build / selection time) and drop the parent-county tint.
			if _selected_barony != "":
				var zoom: float = camera.zoom.x
				for child in border_layer.get_children():
					if str(child.get_meta("barony_id", "")) != _selected_barony:
						continue
					var base_color: Color = child.get_meta("base_color", Color.WHITE)
					var base_px: float = float(child.get_meta("base_screen_px",
							child.get_meta("screen_px", 1.4)))
					child.set_meta("screen_px", base_px)
					if child is Line2D:
						var line: Line2D = child
						line.default_color = base_color
						line.width = base_px / max(zoom, 0.0001)
					elif child.has_method("queue_redraw"):
						child.color = base_color
						child.screen_px = base_px
						child.queue_redraw()
			for cn in MapData.counties:
				_tint_county(cn, NORMAL_TINT)
	_selected_country = ""
	_selected_duchy = ""
	_selected_barony = ""


# ── TOOLTIP ───────────────────────────────────────────────────────────────────

# Update or hide the hover tooltip based on what's under the cursor at the
# current zoom band. Mirrors the click hit-test logic so the tooltip names
# exactly what would be selected if the user clicked.
#
# Args:
#   screen_pos (Vector2): mouse position in screen coordinates (for placement).
#   world_pos  (Vector2): mouse position in world coordinates (for hit-test).
# Returns: void
func _update_tooltip(screen_pos: Vector2, world_pos: Vector2) -> void:
	if tooltip == null or tooltip_label == null:
		return
	var hit: Dictionary = _hit_test_at_band(world_pos)
	if hit.is_empty():
		tooltip.visible = false
		return
	tooltip_label.text = str(hit.get("name", ""))
	# Place 16px right + 16px below the cursor.
	tooltip.position = screen_pos + Vector2(16, 16)
	tooltip.visible = true


func _hide_tooltip() -> void:
	if tooltip != null:
		tooltip.visible = false


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
	if _selected_type == "county" and county_name == _selected_county_name:
		return  # idempotent
	_clear_selection_tint()
	_selected_type = "county"
	_selected_county_name = county_name
	_tint_county(county_name, SELECTED_TINT)

	var data: Dictionary = MapData.get_county(county_name).duplicate()
	data["type"] = "county"
	data["name"] = county_name
	ui.update_panel_typed(data)


# Reset the current selection: drop tinting AND hide the InfoPanel.
func _clear_selection() -> void:
	_clear_selection_tint()
	_selected_type = ""
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
