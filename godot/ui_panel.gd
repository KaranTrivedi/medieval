# ui_panel.gd
# Right-side InfoPanel for the campaign map. Receives county data via
# update_panel() from CampaignMap, and owns the Save button which writes the
# working DB to a timestamped slot via the GameState autoload.

extends CanvasLayer

@onready var county_name_label: Label  = $Control/InfoPanel/VBoxContainer/CountyName
@onready var duchy_label: Label        = $Control/InfoPanel/VBoxContainer/DuchySection/DuchyValue
@onready var earl_label: Label         = $Control/InfoPanel/VBoxContainer/GovernanceSection/EarlHBox/EarlValue
@onready var income_label: Label       = $Control/InfoPanel/VBoxContainer/GovernanceSection/IncomeHBox/IncomeValue
@onready var garrison_label: Label     = $Control/InfoPanel/VBoxContainer/GovernanceSection/GarrisonHBox/GarrisonValue
@onready var population_label: Label   = $Control/InfoPanel/VBoxContainer/GovernanceSection/PopulationHBox/PopulationValue
@onready var save_button: Button       = $Control/InfoPanel/VBoxContainer/SaveButton


# Engine-invoked. Wires up the Save button and resets fields to placeholders.
func _ready() -> void:
	print("UI Panel initialized")
	save_button.pressed.connect(_on_save_pressed)
	clear_panel()
	visible = true


# Reset all data labels back to em-dash placeholders.
#
# Returns: void
func clear_panel() -> void:
	county_name_label.text = "-"
	duchy_label.text = "—"
	earl_label.text = "—"
	income_label.text = "— £/yr"
	garrison_label.text = "—"
	population_label.text = "—"


# Populate the panel for one county.
#
# Args:
#   county_data (Dictionary): Row from MapData.get_county(name). Keys read here:
#       "duchy" (String), "earl" (String), "income" (int), "garrison" (int),
#       "population" (int). Missing keys default to "—" or 0.
#   county_name (String): Display name for the title row. Underscores are
#       converted to spaces for readability.
# Returns: void
func update_panel(county_data: Dictionary, county_name: String) -> void:
	print("Updating panel for: " + county_name)
	county_name_label.text = county_name.replace("county", "-")
	duchy_label.text = county_data.get("duchy", "—").capitalize()
	earl_label.text = county_data.get("earl", "—")

	var income: int = int(county_data.get("income", 0))
	income_label.text = "%d £/yr" % income

	var garrison: int = int(county_data.get("garrison", 0))
	garrison_label.text = "%d troops" % garrison

	var population: int = int(county_data.get("population", 0))
	population_label.text = "%d people" % population


# Save button handler. Writes a timestamped copy of the working DB into
# user://saves/. The working DB itself is always up-to-date — this is purely
# a manual checkpoint the player can return to.
#
# Returns: void
func _on_save_pressed() -> void:
	# Replace ':' so the timestamp is a valid Windows filename.
	var ts: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = "user://saves/save_%s.db" % ts
	var ok: bool = GameState.save_to(path)
	if ok:
		print("UI: saved to ", path)
		save_button.text = "Saved!"
		await get_tree().create_timer(1.2).timeout
		save_button.text = "Save Game"
	else:
		push_error("UI: save failed")
