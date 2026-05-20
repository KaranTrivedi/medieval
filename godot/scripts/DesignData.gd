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
var counties: Dictionary = {}              # county_id  → {earl}  (NO economy)
var duchies:  Dictionary = {}              # duchy_id   → {name, color, lord}
var baronies: Dictionary = {}              # LAD13CD    → {income, garrison, population, name?}
var monarchs: Dictionary = {}              # faction_id → {given, surname, title, age}
var barony_holders: Dictionary = {}        # LAD13CD    → {given, surname, title, age}
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
	baronies               = d.get("baronies", {})
	monarchs               = d.get("monarchs", {})
	barony_holders         = d.get("barony_holders", {})
	fertility_by_duchy     = d.get("fertility_by_duchy", {})
	default_harvest_params = d.get("default_harvest_params", [])
	faction_seed           = d.get("faction_seed", [])
	country_by_duchy       = d.get("country_by_duchy", {})
	factions_by_duchy      = d.get("factions_by_duchy", {})
	loaded = true
	print("DesignData: loaded %d counties, %d duchies, %d baronies, %d monarchs, %d barony holders" % [
		counties.size(), duchies.size(), baronies.size(),
		monarchs.size(), barony_holders.size()
	])


# ── ACCESSORS ────────────────────────────────────────────────────────────────

func county(cn: String) -> Dictionary:
	return counties.get(cn, {})


func duchy(did: String) -> Dictionary:
	return duchies.get(did, {})


# Per-barony economy. Reads the authoritative per-LAD dict; falls back to
# a tiny placeholder if the LAD isn't in the design file (would only happen
# for a barony that exists in geometry but extract_design.py didn't see —
# i.e. design out of date relative to geometry).
#
# Args:
#   lad_code (String): LAD13CD identifier (e.g. "E08000034").
# Returns:
#   Dictionary: {income, garrison, population, (name)}
func barony_economy(lad_code: String) -> Dictionary:
	return baronies.get(lad_code, {"income": 0, "garrison": 0, "population": 0})


# Aggregate the baronies that belong to a given county into a single
# {income, garrison, population} dict. County totals are derived this way
# now — they're no longer stored directly.
#
# Args:
#   barony_ids (Array): LAD13CD strings for the county's baronies (sourced
#       from MapData.counties[cn].baronies[i].id).
# Returns:
#   Dictionary: summed totals across all baronies.
func county_economy_from_baronies(barony_ids: Array) -> Dictionary:
	var total: Dictionary = {"income": 0, "garrison": 0, "population": 0}
	for lad in barony_ids:
		var b: Dictionary = baronies.get(lad, {})
		total.income += int(b.get("income", 0))
		total.garrison += int(b.get("garrison", 0))
		total.population += int(b.get("population", 0))
	return total
