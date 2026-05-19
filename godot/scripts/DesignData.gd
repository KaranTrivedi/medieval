# DesignData.gd
# Autoload singleton. Loads data/gb_design.json (the hand-authored design
# layer: lord names, baseline economy, fertility, harvest curves, country
# mappings) so the rest of the game can stop hard-coding these values.
#
# Loaded BEFORE MapData in the autoload order — MapData's _load_map then
# merges design fields onto the geometry dicts so downstream callers keep
# using MapData.counties[cn].earl, etc., transparently.

extends Node

const PATH := "res://data/gb_design.json"

# Top-level sections of gb_design.json, all exposed as plain dicts/arrays.
var counties: Dictionary = {}              # county_id  → {earl, income, garrison, population}
var duchies:  Dictionary = {}              # duchy_id   → {name, color, lord}
var fertility_by_duchy: Dictionary = {}
var default_harvest_params: Array = []
var faction_seed: Array = []
var country_by_duchy: Dictionary = {}
var factions_by_duchy: Dictionary = {}

var loaded: bool = false


func _ready() -> void:
	_load()


func _load() -> void:
	if not FileAccess.file_exists(PATH):
		push_error("DesignData: missing %s — run extract_design.py" % PATH)
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(raw) != OK:
		push_error("DesignData: parse error — %s" % parser.get_error_message())
		return
	var d: Dictionary = parser.get_data()
	counties               = d.get("counties", {})
	duchies                = d.get("duchies", {})
	fertility_by_duchy     = d.get("fertility_by_duchy", {})
	default_harvest_params = d.get("default_harvest_params", [])
	faction_seed           = d.get("faction_seed", [])
	country_by_duchy       = d.get("country_by_duchy", {})
	factions_by_duchy      = d.get("factions_by_duchy", {})
	loaded = true
	print("DesignData: loaded %d counties, %d duchies" % [counties.size(), duchies.size()])


# Convenience accessors.
func county(cn: String) -> Dictionary:
	return counties.get(cn, {})


func duchy(did: String) -> Dictionary:
	return duchies.get(did, {})
