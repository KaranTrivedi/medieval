# ui_panel.gd
extends CanvasLayer

@onready var county_name_label = $Control/InfoPanel/VBoxContainer/CountyName
@onready var duchy_label = $Control/InfoPanel/VBoxContainer/DuchySection/DuchyValue
@onready var earl_label = $Control/InfoPanel/VBoxContainer/GovernanceSection/EarlHBox/EarlValue
@onready var income_label = $Control/InfoPanel/VBoxContainer/GovernanceSection/IncomeHBox/IncomeValue
@onready var garrison_label = $Control/InfoPanel/VBoxContainer/GovernanceSection/GarrisonHBox/GarrisonValue
@onready var population_label = $Control/InfoPanel/VBoxContainer/GovernanceSection/PopulationHBox/PopulationValue

func _ready():
	print("UI Panel initialized")
	clear_panel()
	# Force visibility
	visible = true

func clear_panel():
	county_name_label.text = "Select a County"
	duchy_label.text = "—"
	earl_label.text = "—"
	income_label.text = "— ₪/yr"
	garrison_label.text = "—"
	population_label.text = "—"

func update_panel(county_data: Dictionary, county_name: String):
	print("Updating panel for: " + county_name)
	county_name_label.text = county_name.replace("_", " ")
	duchy_label.text = county_data.get("duchy", "—").capitalize()
	earl_label.text = county_data.get("earl", "—")
	
	var income = county_data.get("income", 0)
	income_label.text = "%d ₪/yr" % income
	
	var garrison = county_data.get("garrison", 0)
	garrison_label.text = "%d troops" % garrison
	
	var population = county_data.get("population", 0)
	population_label.text = "%d people" % population
