extends Node2D

@export var world_scale := Vector2(1, 1)

func _ready():
	draw_map()

func draw_map():
	for county_id in MapData.counties.keys():

		var polys = MapData.get_polygons(county_id, world_scale)

		for poly in polys:

			var p := Polygon2D.new()
			p.polygon = poly

			# random visible color
			p.color = Color.from_hsv(randf(), 0.6, 0.9)

			add_child(p)

# extends Node2D

# func _ready():
# 	if MapData.is_loaded:
# 		_build()
# 	else:
# 		MapData.map_loaded.connect(_build)

# func _build():
# 	MapData.build_county_polygons($CountyLayer, Vector2(4, 4))
