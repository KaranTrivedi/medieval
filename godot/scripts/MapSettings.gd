# MapSettings.gd
# Autoload singleton — user-tunable map rendering settings, persisted to
# user://map_settings.cfg so they survive across sessions.
#
# Surfaced to:
#   - CampaignMap (zoom-band thresholds for label LOD)
#   - MapData    (border widths in screen pixels)
# Both listen to the `changed` signal and reapply when sliders move.

extends Node

const PATH := "user://map_settings.cfg"

# ── zoom thresholds (label LOD) ───────────────────────────────────────────────
# Bands are mutually exclusive:
#   z < country_zoom_max          → COUNTRY labels
#   country_zoom_max..duchy       → DUCHY labels
#   duchy..county_zoom_max        → COUNTY labels
#   z >= county_zoom_max          → (reserved) fief tier
var country_zoom_max: float = 0.07
var duchy_zoom_max:   float = 0.55
var county_zoom_max:  float = 3.50

# ── border widths (screen pixels) ─────────────────────────────────────────────
var county_border_px: float = 0.8
var duchy_border_px:  float = 5.5

signal changed


func _ready() -> void:
	load_from_disk()


# Load settings file. If it doesn't exist or a key is missing, the field's
# initial value above is kept (so this is forward-compatible with new keys).
func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	country_zoom_max = float(cfg.get_value("zoom", "country_max", country_zoom_max))
	duchy_zoom_max   = float(cfg.get_value("zoom", "duchy_max",   duchy_zoom_max))
	county_zoom_max  = float(cfg.get_value("zoom", "county_max",  county_zoom_max))
	county_border_px = float(cfg.get_value("borders", "county_px", county_border_px))
	duchy_border_px  = float(cfg.get_value("borders", "duchy_px",  duchy_border_px))


# Persist current values to disk. Emits `changed` after writing so all
# listeners refresh in one go.
func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("zoom", "country_max", country_zoom_max)
	cfg.set_value("zoom", "duchy_max",   duchy_zoom_max)
	cfg.set_value("zoom", "county_max",  county_zoom_max)
	cfg.set_value("borders", "county_px", county_border_px)
	cfg.set_value("borders", "duchy_px",  duchy_border_px)
	cfg.save(PATH)
	changed.emit()


# Single-call setter pattern keeps the listeners' refresh count down.
func update_zoom_bands(country: float, duchy: float, county: float) -> void:
	country_zoom_max = country
	duchy_zoom_max   = duchy
	county_zoom_max  = county
	save_to_disk()


func update_border_widths(county_px: float, duchy_px: float) -> void:
	county_border_px = county_px
	duchy_border_px  = duchy_px
	save_to_disk()


# Reset to the hard-coded defaults and persist. Useful for a Reset button.
func restore_defaults() -> void:
	country_zoom_max = 0.07
	duchy_zoom_max   = 0.55
	county_zoom_max  = 3.50
	county_border_px = 0.8
	duchy_border_px  = 5.5
	save_to_disk()
