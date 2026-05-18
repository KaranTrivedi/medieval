# GameState.gd
# Autoload singleton — owns the SQLite-backed mutable game state.
#
# DATA SPLIT
#   res://data/england_godot.json  — IMMUTABLE map geometry/topology (MapData)
#   user://current.db              — LIVE working save (auto-resumes)
#   user://saves/slot*.db          — explicit checkpoints from the Save button
#
# Schema lives below as `_migrate()`. Schema version is recorded in the `meta`
# table; future versions add ALTERs gated on that value.

extends Node

const SCHEMA_VERSION := 1
const WORKING_DB := "user://current.db"
const SAVES_DIR  := "user://saves/"

# Maps duchy id (from england_godot.json) to faction id. The data file only
# carries duchies; factions are a higher-level grouping we control here.
const FACTIONS_BY_DUCHY := {
	"lancaster":  "england",
	"chester":    "england",
	"march":      "england",
	"gloucester": "england",
	"norfolk":    "england",
	"cornwall":   "england",
	"wales":      "wales",
	"scotland":   "scotland",
}

const FACTION_SEED := [
	{"id": "england",  "name": "Kingdom of England",   "color_hex": "#c8102e", "treasury": 2500},
	{"id": "wales",    "name": "Principality of Wales","color_hex": "#00693e", "treasury": 600},
	{"id": "scotland", "name": "Kingdom of Scotland",  "color_hex": "#005eb8", "treasury": 900},
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
#   1. For every county the player owns, roll a Gaussian harvest multiplier
#      (per Project.md §10) against the static base income from MapData and
#      sum the rolled incomes.
#   2. Credit the total to the player's treasury.
#   3. Advance the turn counter.
#
# Args: none — operates on player_faction_id.
# Returns:
#   Dictionary: {
#       "turn":          int,    # the new turn number (after advancing)
#       "total_income":  int,    # treasury delta this turn
#       "counties":      Array,  # [{id, base, mult, income}, ...] per county
#       "treasury":      int,    # treasury value AFTER applying income
#   }
func end_turn() -> Dictionary:
	var summary: Dictionary = {"counties": [], "total_income": 0}

	db.query_with_bindings(
		"SELECT county_id FROM counties_state WHERE owner_faction_id = ?;",
		[player_faction_id]
	)
	# Copy the result rows now — adjust_treasury below issues its own queries
	# that would overwrite db.query_result mid-iteration.
	var owned_ids: Array = []
	for row in db.query_result:
		owned_ids.append(row["county_id"])

	var total: int = 0
	for cid in owned_ids:
		var co: Dictionary = MapData.get_county(cid)
		var base: int = int(co.get("income", 0))
		var mult: float = GaussianSystem.harvest_roll()
		var income: int = roundi(base * mult)
		total += income
		summary.counties.append({"id": cid, "base": base, "mult": mult, "income": income})

	summary.total_income = total
	if total != 0:
		# adjust_treasury also emits state_changed, but we'll emit again after
		# advance_turn so listeners only need one refresh per end-turn.
		db.query_with_bindings(
			"UPDATE factions SET treasury = treasury + ? WHERE id = ?;",
			[total, player_faction_id]
		)

	summary.turn = advance_turn()  # advance_turn emits state_changed
	summary.treasury = int(faction(player_faction_id).get("treasury", 0))
	return summary


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


# Create the schema if missing. Idempotent: re-running on an already-migrated
# DB is a no-op. Future schema versions will add ALTER TABLE statements gated
# on the stored schema_version.
func _migrate() -> void:
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
	db.query("CREATE INDEX IF NOT EXISTS idx_counties_owner ON counties_state(owner_faction_id);")
	db.query_with_bindings(
		"INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?);",
		[str(SCHEMA_VERSION)]
	)


# Populate factions + counties_state from MapData. INSERT OR IGNORE makes this
# safe to call on an existing seeded DB (it won't clobber treasuries etc).
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
		db.query_with_bindings(
			"INSERT OR IGNORE INTO counties_state(county_id, owner_faction_id, garrison, updated_turn) VALUES(?,?,?,?);",
			[cname, owner, garrison, 0]
		)

	if current_turn() == 0:
		advance_turn()
