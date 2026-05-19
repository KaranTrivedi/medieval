# settings_panel.gd
# Floating Settings panel toggled by the O key. Lets the user tune the zoom-
# band thresholds (where labels swap between country/duchy/county tiers) and
# the border line thicknesses. Values live in the MapSettings autoload and
# are persisted to user://map_settings.cfg every change.
#
# The panel is built programmatically in _ready() rather than authored in a
# scene file, so adding/removing sliders is a one-line GDScript edit.

extends Panel

# Each slider entry: ("label", min, max, step, settings_property_name)
const SLIDERS := [
	["Country zoom max",   0.01,  0.30, 0.005, "country_zoom_max"],
	["Duchy zoom max",     0.05,  2.00, 0.01,  "duchy_zoom_max"],
	["County zoom max",    0.20,  8.00, 0.05,  "county_zoom_max"],
	["County border px",   0.20,  4.00, 0.05,  "county_border_px"],
	["Duchy border px",    1.00, 12.00, 0.10,  "duchy_border_px"],
]

var _value_labels: Array = []     # parallel to SLIDERS — Label nodes showing live values


func _ready() -> void:
	# Anchor centred, fixed-size column.
	custom_minimum_size = Vector2(330, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var vbox := VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.offset_left = 14
	vbox.offset_top = 12
	vbox.offset_right = -14
	vbox.offset_bottom = -12
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)

	var title := Label.new()
	title.text = "Map Settings"
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	for i in range(SLIDERS.size()):
		var entry: Array = SLIDERS[i]
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		vbox.add_child(row)

		var header_hbox := HBoxContainer.new()
		row.add_child(header_hbox)
		var name_lbl := Label.new()
		name_lbl.text = entry[0]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header_hbox.add_child(name_lbl)
		var value_lbl := Label.new()
		value_lbl.text = "%.3f" % float(MapSettings.get(entry[4]))
		header_hbox.add_child(value_lbl)
		_value_labels.append(value_lbl)

		var slider := HSlider.new()
		slider.min_value = entry[1]
		slider.max_value = entry[2]
		slider.step = entry[3]
		slider.value = float(MapSettings.get(entry[4]))
		slider.custom_minimum_size = Vector2(0, 22)
		# Capture i so the lambda updates the right slot.
		var idx := i
		slider.value_changed.connect(func(v): _on_slider_changed(idx, v))
		row.add_child(slider)

	# Separator
	var sep := HSeparator.new()
	vbox.add_child(sep)

	# Save / DB Browser / Main Menu — actions consolidated here per the
	# user's request to pull these out of the right-side InfoPanel.
	var save_btn := Button.new()
	save_btn.text = "Save Game"
	save_btn.pressed.connect(_on_save_pressed)
	vbox.add_child(save_btn)
	_save_button = save_btn

	var db_btn := Button.new()
	db_btn.text = "DB Browser"
	db_btn.pressed.connect(_on_db_browser_pressed)
	vbox.add_child(db_btn)

	var hier_btn := Button.new()
	hier_btn.text = "Realm Hierarchy"
	hier_btn.pressed.connect(_on_hierarchy_pressed)
	vbox.add_child(hier_btn)

	var menu_btn := Button.new()
	menu_btn.text = "Quit to Main Menu"
	menu_btn.pressed.connect(_on_main_menu_pressed)
	vbox.add_child(menu_btn)

	# Action row at the bottom: Reset + Close.
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	vbox.add_child(actions)
	var reset := Button.new()
	reset.text = "Reset defaults"
	reset.pressed.connect(_on_reset_pressed)
	reset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(reset)
	var close := Button.new()
	close.text = "Close (O)"
	close.pressed.connect(func(): visible = false)
	close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(close)


var _save_button: Button = null


# Save the current working DB to a timestamped slot in user://saves/.
# Briefly flashes the button label so the user gets visible feedback.
func _on_save_pressed() -> void:
	var ts: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = "user://saves/save_%s.db" % ts
	var ok: bool = GameState.save_to(path)
	if ok and _save_button:
		_save_button.text = "Saved!"
		await get_tree().create_timer(1.2).timeout
		if is_instance_valid(_save_button):
			_save_button.text = "Save Game"
	elif not ok:
		push_error("Settings: save failed")


# Return to the main menu (which is also the load/delete screen).
func _on_main_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://MainMenu.tscn")


# Toggle the SQLite DB Browser. The browser is a sibling node under
# UI/Control — we walk up from this Panel to reach it.
func _on_db_browser_pressed() -> void:
	# Settings panel is at UI/Control/SettingsPanel; sibling is UI/Control/DbBrowser.
	var browser := get_node_or_null("../DbBrowser")
	if browser != null:
		browser.visible = not browser.visible
		if browser.visible and browser.has_method("_refresh_tables"):
			browser._refresh_tables()


# Toggle the cascading Country→Duchy→County→Barony hierarchy panel.
func _on_hierarchy_pressed() -> void:
	var panel := get_node_or_null("../CascadingPanel")
	if panel != null:
		panel.visible = not panel.visible
		if panel.visible and panel.has_method("refresh_tree"):
			panel.refresh_tree()


# Slider drag handler. Writes back to MapSettings (which persists + emits
# its `changed` signal), and updates the inline value readout.
#
# Args:
#   idx (int): slider index into SLIDERS.
#   v (float): new slider value.
# Returns: void
func _on_slider_changed(idx: int, v: float) -> void:
	var prop_name: String = SLIDERS[idx][4]
	MapSettings.set(prop_name, v)
	MapSettings.save_to_disk()
	_value_labels[idx].text = "%.3f" % v


# Reset button: restore defaults, push slider values back to match.
func _on_reset_pressed() -> void:
	MapSettings.restore_defaults()
	# Walk children to find sliders by traversal order — they're the only
	# HSlider nodes we added, in the same order as SLIDERS.
	var slider_i := 0
	for child in $VBoxContainer.get_children() if has_node("VBoxContainer") else get_children():
		_sync_slider_in_subtree(child, slider_i)
		# slider_i is bumped inside _sync_slider_in_subtree


func _sync_slider_in_subtree(node: Node, _slider_i_ignored: int) -> void:
	# Walk depth-first and reset any HSlider value from the matching
	# MapSettings property by SLIDERS order.
	for child in node.get_children():
		if child is HSlider:
			var idx: int = _find_slider_index(child)
			if idx >= 0:
				(child as HSlider).value = float(MapSettings.get(SLIDERS[idx][4]))
				_value_labels[idx].text = "%.3f" % float(MapSettings.get(SLIDERS[idx][4]))
		_sync_slider_in_subtree(child, 0)


# Find which SLIDERS row this HSlider belongs to by checking its current
# value range against the entry ranges. Used by Reset to map back.
func _find_slider_index(slider: HSlider) -> int:
	for i in range(SLIDERS.size()):
		var e: Array = SLIDERS[i]
		if is_equal_approx(slider.min_value, float(e[1])) and is_equal_approx(slider.max_value, float(e[2])):
			return i
	return -1
