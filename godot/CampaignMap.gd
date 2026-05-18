extends Node2D

@onready var county_layer = $CountyLayer
@onready var camera = $Camera2D

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
		var vp_size := get_viewport_rect().size
		# Fit-to-screen with 10% margin. Larger zoom values = more zoomed in.
		var zx := vp_size.x / (bbox.size.x * 1.1)
		var zy := vp_size.y / (bbox.size.y * 1.1)
		var z := minf(zx, zy)
		camera.zoom = Vector2(z, z)
	else:
		camera.position = Vector2(1500, 170)
		camera.zoom = Vector2(0.08, 0.08)

	print("Camera: position=%v, zoom=%v" % [camera.position, camera.zoom])
	print("=== build_map() END ===")

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
