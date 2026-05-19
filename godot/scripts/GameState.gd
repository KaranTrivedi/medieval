# GameState.gd
# Autoload singleton — owns the SQLite-backed mutable game state.
#
# DATA SPLIT
#   res://data/bg_godot.json  — IMMUTABLE map geometry/topology (MapData)
#   user://current.db              — LIVE working save (auto-resumes)
#   user://saves/slot*.db          — explicit checkpoints from the Save button
#
# Schema lives below as `_migrate()`. Schema version is recorded in the `meta`
# table; future versions add ALTERs gated on that value.

extends Node

const SCHEMA_VERSION := 2
const WORKING_DB := "user://current.db"
const SAVES_DIR  := "user://saves/"

# Maps duchy id (from bg_godot.json) to faction id. The data file only
# carries duchies; factions are a higher-level grouping we control here.
# Note: Welsh "morgannwg" is held by Norman Marcher lords loyal to England,
# so it belongs to the English faction at game start despite being on Welsh
# soil — this matches the historical 1247 setting.
const FACTIONS_BY_DUCHY := {
	# English duchies
	"lancaster":  "england",
	"chester":    "england",
	"march":      "england",
	"gloucester": "england",
	"norfolk":    "england",
	"cornwall":   "england",
	# Welsh duchies
	"gwynedd":    "wales",
	"deheubarth": "wales",
	"morgannwg":  "england",   # Marcher lords swore to the English crown
	# Scottish duchies
	"highlands":  "scotland",
	"moray":      "scotland",
	"lothian":    "scotland",
	# Legacy fallbacks for v1 saves predating the subdivision
	"wales":      "wales",
	"scotland":   "scotland",
}

const FACTION_SEED := [
	{"id": "england",  "name": "Kingdom of England",   "color_hex": "#c8102e", "treasury": 2500},
	{"id": "wales",    "name": "Principality of Wales","color_hex": "#00693e", "treasury": 600},
	{"id": "scotland", "name": "Kingdom of Scotland",  "color_hex": "#005eb8", "treasury": 900},
]

# Baseline fertility per duchy. Counties inherit their duchy's value as a
# starting point and get small per-county Gaussian noise on top. Tunable
# without re-seeding existing saves (only used during _seed for new games).
#   1.00 = baseline / median expectation
#   1.20 = breadbasket (East Anglia / Kent — heavy clay loams, mild winters)
#   0.80 = harsh climate or upland (Northumberland, mountainous Wales)
#   0.65 = poor agricultural land (Highlands)
const FERTILITY_BY_DUCHY := {
	"lancaster":  0.82,   # Yorkshire grade, harsher in Northumberland
	"chester":    0.95,   # Midlands average
	"march":      0.88,   # Welsh Marches, hilly border
	"gloucester": 1.08,   # Severn vale, Cotswold sheep country
	"norfolk":    1.22,   # the English breadbasket
	"cornwall":   1.00,   # mixed: rich Somerset to thin Devon
	"gwynedd":    0.78,   # Welsh mountains, hard farming
	"powys":      0.82,   # Welsh midlands
	"deheubarth": 0.92,   # south-Welsh river valleys
	"glamorgan":  0.95,   # south-Welsh coastal plain
	"highlands":  0.65,   # north-Scottish uplands
	"moray":      0.85,   # north-east coastal Scotland
	"strathearn": 0.92,   # central Scottish lowlands (Perthshire, Fife)
	"lothian":    1.05,   # Edinburgh hinterland, best Scottish farmland
	"galloway":   0.82,   # south-west Scotland, pastoral
	# Legacy fallback duchies left from the v1 monolithic Wales/Scotland — only
	# referenced if a save predates the LAD subdivision regen.
	"wales":      0.85,
	"scotland":   0.70,
}

# Default seasonal harvest distributions, used to seed harvest_params on a
# fresh DB. Mutable in-game via set_harvest_params() so climate events can
# shift them. Mean/std_dev/min/max are MULTIPLIERS applied to a county's
# (base_income × fertility).
#
# Why this shape:
#   Spring (planting)  — light cashflow from Lenten markets and animal stock
#   Summer (growth)    — wool shearing, modest income
#   Autumn (harvest)   — the year's main grain income with high Gaussian variance
#   Winter (storage)   — stored goods, fines, scant trade
#
# Across one year the sum totals ≈ 2.1× base income on average, matching the
# "3× seed planted" historical norm in Project.md §10 (where 1× of base is
# already factored into the static income figures).
const DEFAULT_HARVEST_PARAMS := [
	{"season": 0, "mean": 0.20, "std_dev": 0.05, "min_val": 0.10, "max_val": 0.40, "description": "Spring — planting, light cashflow"},
	{"season": 1, "mean": 0.30, "std_dev": 0.08, "min_val": 0.15, "max_val": 0.60, "description": "Summer — pasturage and wool"},
	{"season": 2, "mean": 1.50, "std_dev": 0.45, "min_val": 0.50, "max_val": 3.00, "description": "Autumn — main grain harvest"},
	{"season": 3, "mean": 0.10, "std_dev": 0.04, "min_val": 0.00, "max_val": 0.25, "description": "Winter — stored goods and fines"},
]

var db: SQLite = null
var player_faction_id: String = "england"

# Fired whenever persistent state mutates. UI panels listen and refresh.
signal state_changed


# Engine-invoked on autoload init. Resumes the working DB if one exists,
# otherwise spins up a fresh game.
#
# Args: none
# Returns: void
func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVES_DIR)
	if FileAccess.file_exists(WORKING_DB):
		_open(WORKING_DB)
		_migrate()
		print("GameState: resumed working save at ", WORKING_DB,
				" (turn=", current_turn(), ")")
	else:
		new_game("england")


# Start a fresh game: deletes any working db, creates the schema, then waits
# for MapData and seeds factions + county ownership.
#
# Args:
#   player_id (String): Faction id the human plays (must exist in FACTION_SEED).
# Returns: void
func new_game(player_id: String) -> void:
	player_faction_id = player_id
	# Critical: close the existing SQLite handle BEFORE deleting the file.
	# Windows locks the file while it's open, so remove_absolute silently
	# fails and the "new game" inherits the old turn count + treasury.
	# Closing first releases the lock so the delete actually succeeds.
	if db != null:
		db.close_db()
		db = null
	if FileAccess.file_exists(WORKING_DB):
		DirAccess.remove_absolute(WORKING_DB)
	_open(WORKING_DB)
	_migrate()
	if not MapData.is_loaded:
		await MapData.map_loaded
	_seed()
	print("GameState: new game started for ", player_id,
			" — turn=", current_turn())
	state_changed.emit()


# Load a save slot into the working DB (so all edits happen on the working
# copy and the slot file is untouched until the next Save).
#
# Args:
#   path (String): user:// path of the slot .db file.
# Returns:
#   bool: true on success, false if the file does not exist or copy failed.
func load_save(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_error("GameState.load_save: no such file " + path)
		return false
	if db != null:
		db.close_db()
	var err := DirAccess.copy_absolute(path, WORKING_DB)
	if err != OK:
		push_error("GameState.load_save: copy failed (err=%d)" % err)
		return false
	_open(WORKING_DB)
	_migrate()
	state_changed.emit()
	return true


# Copy the working DB to the given save slot. The DB is closed-then-reopened
# around the copy so SQLite has flushed its journal to disk first.
#
# Args:
#   path (String): destination user:// path (creates parent dir if needed).
# Returns:
#   bool: true on success.
func save_to(path: String) -> bool:
	if db == null:
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	db.close_db()
	var err := DirAccess.copy_absolute(WORKING_DB, path)
	db.open_db()  # always reopen, even on copy failure, so we don't strand the session
	if err != OK:
		push_error("GameState.save_to: copy failed (err=%d) to %s" % [err, path])
		return false
	print("GameState: saved to ", path)
	return true


# ── QUERIES ───────────────────────────────────────────────────────────────────

# Read the latest turn number (or 0 if no turns exist yet).
func current_turn() -> int:
	db.query("SELECT MAX(turn_number) AS t FROM turns;")
	if db.query_result.is_empty() or db.query_result[0]["t"] == null:
		return 0
	return int(db.query_result[0]["t"])


# Run one full end-of-turn step for the player faction:
#   1. Resolve the season being ended (turn N occupies season (N-1) % 4 per
#      advance_turn). Look up its Gaussian params from harvest_params.
#   2. For every county the player owns, roll N(mean, σ) clamped to
#      [min_val, max_val] for THIS SEASON, then multiply by base_income and
#      county fertility. Sum the rolled incomes.
#   3. Credit the total to the player's treasury.
#   4. Advance the turn counter (which moves us into the next season).
#
# Args: none — operates on player_faction_id and the season of the current turn.
# Returns:
#   Dictionary: {
#       "turn":          int,     # new turn number (after advancing)
#       "season_ended":  int,     # season index 0..3 just resolved
#       "season_name":   String,  # human-readable
#       "total_income":  int,     # treasury delta this turn
#       "counties":      Array,   # per-county [{id, base, fertility, mult, income}]
#       "treasury":      int,     # treasury value AFTER applying income
#   }
func end_turn() -> Dictionary:
	const SEASON_NAMES := ["Spring", "Summer", "Autumn", "Winter"]
	var summary: Dictionary = {"counties": [], "total_income": 0}

	# The CURRENT turn's season is what we're resolving. advance_turn() at the
	# bottom will move us into the next one.
	var cur_turn: int = maxi(current_turn(), 1)
	var season_idx: int = (cur_turn - 1) % 4
	var params: Dictionary = get_harvest_params(season_idx)

	db.query_with_bindings(
		"SELECT county_id, fertility FROM counties_state WHERE owner_faction_id = ?;",
		[player_faction_id]
	)
	# Snapshot now — sample_clamped / adjust_treasury issue their own queries
	# that would otherwise stomp db.query_result mid-iteration.
	var owned: Array = []
	for row in db.query_result:
		owned.append({"id": row["county_id"], "fertility": float(row["fertility"])})

	var total: int = 0
	for o in owned:
		var co: Dictionary = MapData.get_county(o.id)
		var base: int = int(co.get("income", 0))
		var mult: float = GaussianSystem.sample_clamped(
			params.mean, params.std_dev, params.min_val, params.max_val
		)
		var income: int = roundi(base * mult * o.fertility)
		total += income
		summary.counties.append({
			"id": o.id, "base": base, "fertility": o.fertility,
			"mult": mult, "income": income,
		})

	summary.total_income = total
	summary.season_ended = season_idx
	summary.season_name = SEASON_NAMES[season_idx]
	if total != 0:
		# Apply treasury delta directly so we only emit state_changed ONCE per
		# end-turn (via advance_turn below) instead of twice.
		db.query_with_bindings(
			"UPDATE factions SET treasury = treasury + ? WHERE id = ?;",
			[total, player_faction_id]
		)

	summary.turn = advance_turn()
	summary.treasury = int(faction(player_faction_id).get("treasury", 0))
	return summary


# Look up the harvest distribution params for one season.
#
# Args:
#   season (int): 0..3 — index into the harvest_params table.
# Returns:
#   Dictionary: {mean, std_dev, min_val, max_val, description}. Falls back to
#       a sensible default if the row is missing (shouldn't happen after
#       _migrate seeds the table, but keeps end_turn robust).
func get_harvest_params(season: int) -> Dictionary:
	db.query_with_bindings("SELECT * FROM harvest_params WHERE season = ?;", [season])
	if db.query_result.is_empty():
		push_warning("harvest_params row missing for season %d — using fallback" % season)
		return {"mean": 1.0, "std_dev": 0.4, "min_val": 0.167, "max_val": 2.0,
				"description": "(fallback)"}
	return db.query_result[0].duplicate()


# Overwrite the params for one season — used by climate events, mod tooling,
# or debug commands. Emits state_changed so any UI showing the distribution
# refreshes.
#
# Args:
#   season (int): 0..3 — which row to update.
#   mean (float): Distribution centre.
#   std_dev (float): Standard deviation (>= 0).
#   min_val (float): Clamp floor.
#   max_val (float): Clamp ceiling.
#   description (String): Free-text label for chronicle/debug display.
# Returns: void
func set_harvest_params(season: int, mean: float, std_dev: float,
		min_val: float, max_val: float, description: String) -> void:
	db.query_with_bindings(
		"INSERT OR REPLACE INTO harvest_params(season, mean, std_dev, min_val, max_val, description) VALUES(?,?,?,?,?,?);",
		[season, mean, std_dev, min_val, max_val, description]
	)
	state_changed.emit()


# Append the next turn row. Year/season derived from turn count, starting at
# 1247 spring (turn 1) per Project.md.
#
# Returns:
#   int: the newly-inserted turn number.
func advance_turn() -> int:
	var prev := current_turn()
	var next := prev + 1
	var season := prev % 4              # 0=Spring,1=Summer,2=Autumn,3=Winter
	var year := 1247 + int(prev / 4)
	db.query_with_bindings(
		"INSERT INTO turns(turn_number, year, season, active_faction_id, processed_at) VALUES(?,?,?,?,?);",
		[next, year, season, player_faction_id, Time.get_datetime_string_from_system()]
	)
	state_changed.emit()
	return next


# Look up one county's mutable state row.
#
# Args:
#   county_id (String): primary key (matches MapData county name e.g. "Yorkshire").
# Returns:
#   Dictionary: column → value, or {} if not found.
func county_state(county_id: String) -> Dictionary:
	db.query_with_bindings("SELECT * FROM counties_state WHERE county_id = ?;", [county_id])
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()


# Patch one county_state row.
#
# Args:
#   county_id (String): primary key.
#   patch (Dictionary): column → new value. Columns not in this dict are untouched.
# Returns: void
func set_county_state(county_id: String, patch: Dictionary) -> void:
	if patch.is_empty():
		return
	# select_rows/update_rows in the addon accept a where-CLAUSE string. To
	# avoid string interpolation of user data, we instead run a parameterised
	# UPDATE manually.
	var cols := []
	var values := []
	for k in patch:
		cols.append("%s = ?" % str(k))
		values.append(patch[k])
	values.append(county_id)
	db.query_with_bindings(
		"UPDATE counties_state SET %s WHERE county_id = ?;" % ", ".join(cols),
		values
	)
	state_changed.emit()


# Fetch one faction row.
#
# Args:
#   id (String): faction id (e.g. "england").
# Returns:
#   Dictionary: column → value, or {} if not found.
func faction(id: String) -> Dictionary:
	db.query_with_bindings("SELECT * FROM factions WHERE id = ?;", [id])
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()


# Apply a delta to a faction's treasury.
#
# Args:
#   faction_id (String): id key into factions.
#   delta (int): positive = income, negative = expense.
# Returns:
#   int: new treasury value (0 if faction not found).
func adjust_treasury(faction_id: String, delta: int) -> int:
	db.query_with_bindings(
		"UPDATE factions SET treasury = treasury + ? WHERE id = ?;",
		[delta, faction_id]
	)
	state_changed.emit()
	var f := faction(faction_id)
	return int(f.get("treasury", 0))


# ── INTERNAL ──────────────────────────────────────────────────────────────────

# Open (or create) the SQLite db at the given path. foreign_keys ON.
func _open(path: String) -> void:
	db = SQLite.new()
	db.path = path
	db.foreign_keys = true
	db.open_db()


# Create or upgrade the schema. Idempotent: safe to re-run on an already-
# migrated DB. Reads meta.schema_version to know what migration steps to
# apply on top of the base CREATE TABLE IF NOT EXISTS layer.
func _migrate() -> void:
	# Base tables — created with the CURRENT schema, so fresh DBs land at
	# the latest version with no per-version ALTER work. Existing v1 DBs
	# skip these CREATEs (table already exists) and get patched below.
	db.query("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);")
	db.query("""
		CREATE TABLE IF NOT EXISTS factions (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			color_hex TEXT NOT NULL,
			treasury INTEGER NOT NULL DEFAULT 0,
			head_char_id INTEGER
		);""")
	db.query("""
		CREATE TABLE IF NOT EXISTS counties_state (
			county_id TEXT PRIMARY KEY,
			owner_faction_id TEXT NOT NULL,
			controller_char_id INTEGER,
			garrison INTEGER NOT NULL DEFAULT 0,
			prosperity INTEGER NOT NULL DEFAULT 50,
			unrest INTEGER NOT NULL DEFAULT 0,
			fertility REAL NOT NULL DEFAULT 1.0,
			updated_turn INTEGER NOT NULL DEFAULT 0,
			FOREIGN KEY (owner_faction_id) REFERENCES factions(id)
		);""")
	db.query("""
		CREATE TABLE IF NOT EXISTS turns (
			turn_number INTEGER PRIMARY KEY,
			year INTEGER NOT NULL,
			season INTEGER NOT NULL,
			active_faction_id TEXT,
			processed_at TEXT
		);""")
	db.query("""
		CREATE TABLE IF NOT EXISTS harvest_params (
			season INTEGER PRIMARY KEY,
			mean REAL NOT NULL,
			std_dev REAL NOT NULL,
			min_val REAL NOT NULL,
			max_val REAL NOT NULL,
			description TEXT
		);""")
	db.query("CREATE INDEX IF NOT EXISTS idx_counties_owner ON counties_state(owner_faction_id);")

	# Version-gated patches for older DBs.
	var prev_version: int = _read_schema_version()
	if prev_version < 2:
		_migrate_to_v2()

	db.query_with_bindings(
		"INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?);",
		[str(SCHEMA_VERSION)]
	)


# Read the stored schema_version. Returns 0 if meta is absent or empty (which
# means "brand-new DB, treat as pre-v1 — every migration step needs to run").
func _read_schema_version() -> int:
	db.query("SELECT value FROM meta WHERE key = 'schema_version';")
	if db.query_result.is_empty():
		return 0
	return int(db.query_result[0]["value"])


# v1 → v2 upgrade. Adds the fertility column to existing counties_state rows
# and back-fills harvest_params from DEFAULT_HARVEST_PARAMS. Safe to run on a
# fresh DB too (no-ops when nothing's missing).
func _migrate_to_v2() -> void:
	# 1. fertility column on counties_state. SQLite can't `ADD COLUMN IF NOT
	#    EXISTS`, so check via PRAGMA before issuing the ALTER.
	db.query("PRAGMA table_info(counties_state);")
	var has_fertility := false
	for row in db.query_result:
		if str(row.get("name", "")) == "fertility":
			has_fertility = true
			break
	if not has_fertility:
		db.query("ALTER TABLE counties_state ADD COLUMN fertility REAL NOT NULL DEFAULT 1.0;")

	# 2. Seed harvest_params if empty. We INSERT OR IGNORE so a partial seed
	#    (somehow) doesn't overwrite player-tuned values.
	db.query("SELECT COUNT(*) AS c FROM harvest_params;")
	if int(db.query_result[0]["c"]) == 0:
		for p in DEFAULT_HARVEST_PARAMS:
			db.query_with_bindings(
				"INSERT OR IGNORE INTO harvest_params(season, mean, std_dev, min_val, max_val, description) VALUES(?,?,?,?,?,?);",
				[p.season, p.mean, p.std_dev, p.min_val, p.max_val, p.description]
			)


# Populate factions + counties_state from MapData. INSERT OR IGNORE makes this
# safe to call on an existing seeded DB (it won't clobber treasuries etc).
#
# Per-county fertility is derived as FERTILITY_BY_DUCHY[duchy] + small Gaussian
# noise (σ=0.08), clamped to [0.4, 1.6]. Counties whose duchy isn't in the
# table fall back to 1.0.
func _seed() -> void:
	for f in FACTION_SEED:
		db.query_with_bindings(
			"INSERT OR IGNORE INTO factions(id, name, color_hex, treasury) VALUES(?,?,?,?);",
			[f.id, f.name, f.color_hex, f.treasury]
		)

	for cname in MapData.counties:
		var co: Dictionary = MapData.counties[cname]
		var duchy: String = co.get("duchy", "")
		var owner: String = FACTIONS_BY_DUCHY.get(duchy, "england")
		var garrison: int = int(co.get("garrison", 0))
		var base_fertility: float = FERTILITY_BY_DUCHY.get(duchy, 1.0)
		var fertility: float = clampf(
			GaussianSystem.sample(base_fertility, 0.08),
			0.4, 1.6
		)
		db.query_with_bindings(
			"INSERT OR IGNORE INTO counties_state(county_id, owner_faction_id, garrison, fertility, updated_turn) VALUES(?,?,?,?,?);",
			[cname, owner, garrison, fertility, 0]
		)

	# For older DBs that arrived here via the v1→v2 migration, the ALTER set
	# every existing row's fertility to 1.0. Back-fill those with the proper
	# duchy-derived value. WHERE fertility = 1.0 is a heuristic that may
	# touch rows the user manually set to 1.0 — acceptable at seed time.
	for cname in MapData.counties:
		var co: Dictionary = MapData.counties[cname]
		var duchy: String = co.get("duchy", "")
		var base_fertility: float = FERTILITY_BY_DUCHY.get(duchy, 1.0)
		var fertility: float = clampf(
			GaussianSystem.sample(base_fertility, 0.08),
			0.4, 1.6
		)
		db.query_with_bindings(
			"UPDATE counties_state SET fertility = ? WHERE county_id = ? AND fertility = 1.0;",
			[fertility, cname]
		)

	if current_turn() == 0:
		advance_turn()
