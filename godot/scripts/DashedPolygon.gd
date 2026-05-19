# DashedPolygon.gd
# Renders a closed polygon as a dashed outline via _draw(). Used for the
# subtle barony-boundary hints that appear when the camera is in the
# COUNTY zoom band — Line2D has no native dash support, hence this.
#
# Line width is given in SCREEN pixels and converted to world units at draw
# time using the current Camera2D zoom, so the dashes look the same thickness
# regardless of how zoomed-in you are.

class_name DashedPolygon
extends Node2D

@export var polygon: PackedVector2Array = []   # world-space vertices, NOT closed
@export var color: Color = Color(0.18, 0.13, 0.07, 0.85)
@export var screen_px: float = 0.6             # target on-screen thickness
@export var dash_world: float = 10.0           # length of each dash, world units
@export var gap_world: float = 6.0             # length of each gap, world units


# Engine-invoked when the node enters the tree. We could leave the default
# behaviour but a queue_redraw is cheap and avoids a one-frame blank state.
func _ready() -> void:
	queue_redraw()


# Tell this node to repaint at the next frame. Called by CampaignMap when
# the zoom changes (so the screen-pixel width is re-resolved).
func refresh() -> void:
	queue_redraw()


# Engine-invoked render callback.
func _draw() -> void:
	if polygon.size() < 2:
		return
	var cam: Camera2D = get_viewport().get_camera_2d()
	var zoom: float = 1.0 if cam == null else cam.zoom.x
	# Convert target screen pixels into world units for the line width.
	# Floor at 0.5 world units so the line never disappears entirely.
	var width: float = maxf(0.5, screen_px / max(zoom, 0.0001))
	var n: int = polygon.size()
	for i in range(n):
		var a: Vector2 = polygon[i]
		var b: Vector2 = polygon[(i + 1) % n]
		_draw_dashed_segment(a, b, width)


# Step along the a→b segment in alternating dash/gap chunks of fixed world
# size; emit a real draw_line() call for each dash.
func _draw_dashed_segment(a: Vector2, b: Vector2, width: float) -> void:
	var seg: Vector2 = b - a
	var seg_len: float = seg.length()
	if seg_len < 0.001:
		return
	var dir: Vector2 = seg / seg_len
	var t: float = 0.0
	var drawing: bool = true
	while t < seg_len:
		var step: float = dash_world if drawing else gap_world
		var end_t: float = minf(t + step, seg_len)
		if drawing:
			draw_line(a + dir * t, a + dir * end_t, color, width, false)
		t = end_t
		drawing = not drawing
