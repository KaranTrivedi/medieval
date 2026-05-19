# main_menu.gd
# Title screen / save-slot manager. Shows New Game, a list of existing save
# slots from user://saves/, and Quit. Each save row gets Load + Delete.
#
# Selecting New Game wipes the working DB so GameState seeds fresh, then
# transitions to CampaignMap. Selecting Load copies the chosen .db into the
# working slot and transitions. Delete just removes the file from disk.

extends Control

const CAMPAIGN_SCENE := "res://CampaignMap.tscn"
const SAVES_DIR := "user://saves/"
const WORKING_DB := "user://current.db"

@onready var saves_list: VBoxContainer = $Panel/VBoxContainer/SavesScroll/SavesList
@onready var no_saves_label: Label = $Panel/VBoxContainer/NoSavesLabel


# Engine-invoked on scene enter. Builds the save-slot rows once at startup.
func _ready() -> void:
	$Panel/VBoxContainer/TitleLabel.text = "MEDIEVAL — KINGDOM OF BRITAIN"
	$Panel/VBoxContainer/NewGameButton.pressed.connect(_on_new_game)
	$Panel/VBoxContainer/QuitButton.pressed.connect(_on_quit)
	_refresh_saves_list()


# Walk user://saves/ and populate a Load/Delete row per .db file.
# Sorts by modified time descending so the most-recent save is on top.
func _refresh_saves_list() -> void:
	for child in saves_list.get_children():
		child.queue_free()

	DirAccess.make_dir_recursive_absolute(SAVES_DIR)
	var dir := DirAccess.open(SAVES_DIR)
	if dir == null:
		no_saves_label.visible = true
		return

	var slots: Array = []
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".db"):
			var full := SAVES_DIR + name
			var mtime: int = FileAccess.get_modified_time(full)
			slots.append({"name": name, "path": full, "mtime": mtime})
		name = dir.get_next()
	dir.list_dir_end()

	slots.sort_custom(func(a, b): return a.mtime > b.mtime)

	no_saves_label.visible = slots.is_empty()
	for s in slots:
		_add_save_row(s.name, s.path, s.mtime)


# Build one row for a save slot: [Filename | Load | Delete].
func _add_save_row(filename: String, full_path: String, mtime: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	saves_list.add_child(row)

	var lbl := Label.new()
	lbl.text = "%s   (%s)" % [filename, Time.get_datetime_string_from_unix_time(mtime)]
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.pressed.connect(func(): _on_load(full_path))
	row.add_child(load_btn)

	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.pressed.connect(func(): _on_delete(full_path))
	row.add_child(del_btn)


# New Game: reset GameState (wipes the working DB AND in-memory state) and
# load the campaign scene.
func _on_new_game() -> void:
	# GameState autoload already ran _ready at app start, so call new_game
	# explicitly to rebuild from a clean slate. await because new_game may
	# yield while MapData finishes loading on a cold boot.
	await GameState.new_game("england")
	get_tree().change_scene_to_file(CAMPAIGN_SCENE)


# Load a slot: copies the chosen .db over the working DB and reloads state.
func _on_load(slot_path: String) -> void:
	GameState.load_save(slot_path)
	get_tree().change_scene_to_file(CAMPAIGN_SCENE)


# Delete a slot from disk and refresh the list.
func _on_delete(slot_path: String) -> void:
	if FileAccess.file_exists(slot_path):
		DirAccess.remove_absolute(slot_path)
	_refresh_saves_list()


func _on_quit() -> void:
	get_tree().quit()
