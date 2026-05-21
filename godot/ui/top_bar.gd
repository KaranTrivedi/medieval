# top_bar.gd
# Top-of-screen status bar. Displays the current turn + season + year, the
# player's faction-wide economy summary (treasury, wealth, fertility), and
# the End Turn / Court / Settings buttons. The Treasury/Wealth/Fertility/
# Political/Geographic chips double as overlay-mode switches: clicking one
# emits `overlay_requested(mode)` for CampaignMap to handle.

extends Panel

@onready var turn_label: Label         = $HBox/TurnLabel
@onready var season_label: Label       = $HBox/SeasonLabel
@onready var treasury_label: Label     = $HBox/TreasuryLabel
@onready var end_turn_button: Button   = $HBox/EndTurnButton
@onready var settings_button: Button   = $HBox/SettingsButton

# Emitted when the "Court" button is pressed. CampaignMap routes this into
# NavRouter so the open also pushes onto the back/forward history.
signal open_court_requested
# Emitted when the player clicks one of the overlay-mode chips. CampaignMap
# listens and calls set_overlay_mode with the matching key.
signal overlay_requested(mode: String)

# Index 0..3 ↔ season number stored in the turns table. Order matches the
# (prev % 4) math in GameState.advance_turn.
const SEASON_NAMES: Array = ["Spring", "Summer", "Autumn", "Winter"]

# Mode keys mirrored from CampaignMap.OVERLAY_*. Kept as plain strings here
# so TopBar doesn't have to import the scene class.
const MODE_POLITICAL := "political"
const MODE_GEOGRAPHIC := "geographic"
const MODE_FERTILITY := "fertility"
const MODE_WEALTH := "wealth"

# Built programmatically in _ready so the .tscn stays minimal. Each chip is
# a flat Button whose font-color brightens when its mode is active.
var _chip_political: Button
var _chip_geographic: Button
var _chip_wealth: Button
var _chip_fertility: Button
var _active_overlay: String = MODE_POLITICAL


# Engine-invoked on scene enter. Wires the button and signal, paints initial
# state from the DB.
#
# Returns: void
func _ready() -> void:
	end_turn_button.pressed.connect(_on_end_turn_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	# Court button: scene-authored sibling of EndTurnButton. Wired here so
	# the .tscn stays declarative; press emits a signal the CampaignMap
	# routes into NavRouter so the open is captured in the history.
	var court_btn: Button = $HBox.get_node_or_null("CourtButton")
	if court_btn != null:
		court_btn.pressed.connect(func(): open_court_requested.emit())
	_build_overlay_chips()
	GameState.state_changed.connect(refresh)
	refresh()


# Public hook called by CampaignMap whenever the active overlay changes (via
# Ctrl+Tab or chip click). Updates the highlighted chip without re-running
# the whole refresh path. Idempotent for repeat-fires.
func set_active_overlay(mode: String) -> void:
	if mode == _active_overlay:
		return
	_active_overlay = mode
	_repaint_chip_states()


# Build the overlay chip strip and insert it before the right-hand action
# buttons. Each chip is a flat Button that emits overlay_requested on press.
# Wealth + Fertility chips also display the player faction's running totals,
# updated in refresh().
func _build_overlay_chips() -> void:
	var hbox: HBoxContainer = $HBox
	_chip_political = _make_chip("👑 Political", MODE_POLITICAL,
			"Show realms coloured by faction ownership.")
	_chip_geographic = _make_chip("📜 Geographic", MODE_GEOGRAPHIC,
			"Show regions coloured by duchy (the original map view).")
	_chip_wealth = _make_chip("💰 —", MODE_WEALTH,
			"Show wealth gradient + your realm's total income. Click to switch.")
	_chip_fertility = _make_chip("🌾 —", MODE_FERTILITY,
			"Show fertility gradient + your realm's mean fertility. Click to switch.")
	# Insert in order Political → Geographic → Wealth → Fertility, right
	# after the existing TreasuryLabel + before the Court / End Turn buttons.
	# Walk to TreasuryLabel's index and place the chips after it.
	var anchor_idx: int = treasury_label.get_index() + 1
	hbox.add_child(_chip_political)
	hbox.add_child(_chip_geographic)
	hbox.add_child(_chip_wealth)
	hbox.add_child(_chip_fertility)
	hbox.move_child(_chip_political, anchor_idx)
	hbox.move_child(_chip_geographic, anchor_idx + 1)
	hbox.move_child(_chip_wealth, anchor_idx + 2)
	hbox.move_child(_chip_fertility, anchor_idx + 3)
	_repaint_chip_states()


# Build a single chip Button styled to match the bar's medieval palette.
func _make_chip(label: String, mode: String, tooltip: String) -> Button:
	var b := Button.new()
	b.text = label
	b.flat = true
	b.tooltip_text = tooltip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(func(): overlay_requested.emit(mode))
	return b


# Recolour every chip so the active mode reads as "on" and the others read
# as muted. Cheap — runs on chip click + Ctrl+Tab + refresh.
func _repaint_chip_states() -> void:
	var dim := Color(0.65, 0.60, 0.50)
	var on := Color(0.98, 0.85, 0.30)   # warm gold for the active chip
	for pair in [
		[_chip_political,  MODE_POLITICAL],
		[_chip_geographic, MODE_GEOGRAPHIC],
		[_chip_wealth,     MODE_WEALTH],
		[_chip_fertility,  MODE_FERTILITY],
	]:
		var btn: Button = pair[0]
		if btn == null:
			continue
		var col: Color = on if str(pair[1]) == _active_overlay else dim
		btn.add_theme_color_override("font_color", col)
		btn.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.55))


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

	# Pull the full faction-wide economy summary in one call so the chips
	# don't each round-trip the DB.
	var summary: Dictionary = GameState.faction_economy_summary(GameState.player_faction_id)
	treasury_label.text = "%d £" % int(summary.get("treasury", 0))
	if _chip_wealth != null:
		_chip_wealth.text = "💰 %s £/yr" % _fmt_thousands(int(summary.get("total_income", 0)))
	if _chip_fertility != null:
		_chip_fertility.text = "🌾 %.2f" % float(summary.get("mean_fertility", 0.0))


# Comma-separated thousands ("12345" → "12,345"). Local copy so TopBar
# doesn't pull in DataTable or ui_theme just for one helper.
func _fmt_thousands(n: int) -> String:
	var s := str(n)
	var sign_prefix := ""
	if s.begins_with("-"):
		sign_prefix = "-"
		s = s.substr(1)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count == 3 and i > 0:
			out = "," + out
			count = 0
	return sign_prefix + out


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
