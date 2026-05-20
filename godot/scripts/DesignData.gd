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
var barony_overrides: Dictionary = {}      # LAD13CD → {income, garrison, population, name?}

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
	barony_overrides       = d.get("barony_overrides", {})
	loaded = true
	print("DesignData: loaded %d counties, %d duchies, %d barony overrides" % [
		counties.size(), duchies.size(), barony_overrides.size()
	])


# Convenience accessors.
func county(cn: String) -> Dictionary:
	return counties.get(cn, {})


func duchy(did: String) -> Dictionary:
	return duchies.get(did, {})


# Per-barony economy. Returns the override entry if we have one for that LAD,
# otherwise a pro-rata slice of the parent county's income/garrison/pop split
# equally across the county's barony count.
#
# Args:
#   lad_code (String): LAD13CD identifier (e.g. "E08000034").
#   county_name (String): parent county name (for the pro-rata fallback).
#   barony_count (int): number of baronies in that county (denominator).
# Returns:
#   Dictionary: {income, garrison, population, (name)}
func barony_economy(lad_code: String, county_name: String, barony_count: int) -> Dictionary:
	if barony_overrides.has(lad_code):
		return barony_overrides[lad_code].duplicate()
	var co: Dictionary = counties.get(county_name, {})
	var n: int = maxi(1, barony_count)
	@warning_ignore("integer_division")
	return {
		"income":     int(co.get("income", 0))     / n,
		"garrison":   int(co.get("garrison", 0))   / n,
		"population": int(co.get("population", 0)) / n,
	}
