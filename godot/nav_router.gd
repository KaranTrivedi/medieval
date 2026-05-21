# nav_router.gd
# Centralised back/forward history for the inspection panels. Every panel
# open (region / character / family tree / court) goes through this node so
# the player can use mouse4 / mouse5 to walk the visit history like a
# browser. Lives under UI/Control next to the panels themselves.
#
# History entries are stored as {kind, params}. `_navigating` guards against
# double-pushes when we open a panel as part of resolving back/forward.

extends Node

@onready var character_panel: Panel = $"../CharacterPanel"
@onready var region_panel:    Panel = $"../RegionPanel"
@onready var family_tree_panel: Panel = $"../FamilyTreePanel"
@onready var court_panel:     Panel = $"../CourtPanel"

# Bounded history so a long-running session doesn't grow without bound.
const HISTORY_MAX := 64

var _history: Array = []
var _cursor: int = -1
var _navigating: bool = false


# ── PUBLIC API ───────────────────────────────────────────────────────────────

func open_character(character_id: int) -> void:
	if character_id <= 0:
		return
	_push("character", [character_id])


func open_region(region_type: String, region_id: String) -> void:
	if region_type == "" or region_id == "":
		return
	_push("region", [region_type, region_id])


func open_family_tree(character_id: int) -> void:
	if character_id <= 0:
		return
	_push("family_tree", [character_id])


func open_court(country_id: String) -> void:
	if country_id == "":
		return
	_push("court", [country_id])


# Walk back through the history. No-op when we're already at the oldest entry.
func back() -> void:
	if _cursor <= 0:
		return
	_cursor -= 1
	_apply_current()


# Walk forward through the history. No-op when we're at the newest entry.
func forward() -> void:
	if _cursor >= _history.size() - 1:
		return
	_cursor += 1
	_apply_current()


# Test affordance — useful for the TopBar to grey out buttons.
func can_back() -> bool: return _cursor > 0
func can_forward() -> bool: return _cursor < _history.size() - 1


# ── INTERNAL ─────────────────────────────────────────────────────────────────

# Push a new entry onto the history, truncating any forward stack, then
# apply it. Skips the push when called from inside a back/forward apply.
func _push(kind: String, params: Array) -> void:
	if _navigating:
		_apply(kind, params)
		return
	# If we backed up and then opened something new, drop the forward branch.
	if _cursor < _history.size() - 1:
		_history.resize(_cursor + 1)
	# Don't push a duplicate of the entry we're already on.
	if _cursor >= 0 and _history_entry_equals(_history[_cursor], kind, params):
		_apply(kind, params)
		return
	_history.append({"kind": kind, "params": params.duplicate()})
	if _history.size() > HISTORY_MAX:
		_history.pop_front()
	_cursor = _history.size() - 1
	_apply(kind, params)


func _history_entry_equals(entry: Dictionary, kind: String, params: Array) -> bool:
	if str(entry.get("kind", "")) != kind:
		return false
	var p: Array = entry.get("params", [])
	if p.size() != params.size():
		return false
	for i in p.size():
		if str(p[i]) != str(params[i]):
			return false
	return true


func _apply_current() -> void:
	if _cursor < 0 or _cursor >= _history.size():
		return
	var entry: Dictionary = _history[_cursor]
	_navigating = true
	_apply(str(entry.kind), entry.params)
	_navigating = false


# Dispatch to the right panel. The `_navigating` flag prevents the panels'
# own re-emissions (e.g. CharacterPanel.navigate_to) from pushing duplicates.
func _apply(kind: String, params: Array) -> void:
	match kind:
		"character":
			if character_panel != null:
				character_panel.show_for(int(params[0]))
		"region":
			if region_panel != null:
				region_panel.show_for(str(params[0]), str(params[1]))
		"family_tree":
			if family_tree_panel != null:
				family_tree_panel.show_for(int(params[0]))
		"court":
			if court_panel != null:
				court_panel.show_for(str(params[0]))
