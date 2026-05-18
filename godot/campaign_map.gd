extends Node2D

func _ready():
	if MapData.is_loaded:
		_build()
	else:
		MapData.map_loaded.connect(_build)

func _build():
	MapData.build_county_polygons($CountyLayer, Vector2(4, 4))
