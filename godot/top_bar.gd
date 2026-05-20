# top_bar.gd
# Top-of-screen status bar. Displays the current turn, season+year, and the
# player's treasury, plus an End Turn button. Listens to GameState's
# state_changed signal so it always reflects the live DB.

extends Panel

@onready var turn_label: Label         = $HBox/TurnLabel
@onready var season_label: Label       = $HBox/SeasonLabel
@onready var treasury_label: Label     = $HBox/TreasuryLabel
@onready var end_turn_button: Button   = $HBox/EndTurnButton
@onready var settings_button: Button   = $HBox/SettingsButton

# Index 0..3 ↔ season number stored in the turns table. Order matches the
# (prev % 4) math in GameState.advance_turn.
const SEASON_NAMES: Array = ["Spring", "Summer", "Autumn", "Winter"]


# Engine-invoked on scene enter. Wires the button and signal, paints initial
# state from the DB.
#
# Returns: void
func _ready() -> void:
	end_turn_button.pressed.connect(_on_end_turn_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	GameState.state_changed.connect(refresh)
	refresh()


# Settings button → toggle the SettingsPanel, which now also hosts Save Game
# and Quit-to-Main-Menu. Mirrors what the O keyboard shortcut does.
func _on_settings_pressed() -> void:
	# TopBar lives at UI/Control/TopBar; the SettingsPanel is at
	# UI/Control/SettingsPanel, so we just walk one level up and pick the
	# sibling. The earlier ../../ was off by one level.
	var panel := get_node_or_null("../SettingsPanel")
	if panel != null:
		panel.visible = not panel.visible


# Repaint every label from current GameState/DB values. Called both at startup
# and whenever GameState emits state_changed.
#
# Returns: void
func refresh() -> void:
	var turn: int = GameState.current_turn()
	# Re-derive year and season from the turn number so this matches whatever
	# advance_turn() wrote (and so the bar stays correct after a save reload).
	var idx: int = maxi(turn - 1, 0)                  # 0-indexed from turn 1
	@warning_ignore("integer_division")
	var year: int = 1247 + (idx / 4)
	var season: int = idx % 4

	turn_label.text = "Turn %d" % turn
	season_label.text = "%s %d" % [SEASON_NAMES[season], year]

	var f: Dictionary = GameState.faction(GameState.player_faction_id)
	treasury_label.text = "%d £" % int(f.get("treasury", 0))


# End Turn button handler. Runs GameState.end_turn() (Gaussian harvest +
# treasury credit + turn advance), logs the summary to the output panel,
# and lets refresh() repaint via the state_changed signal.
#
# Returns: void
func _on_end_turn_pressed() -> void:
	end_turn_button.disabled = true
	var summary: Dictionary = GameState.end_turn()
	print("Turn %d ended. +%d £ across %d counties → treasury %d £" % [
		summary.turn,
		summary.total_income,
		summary.counties.size(),
		summary.treasury,
	])
	end_turn_button.disabled = false
