# GameState.gd
# Autoload singleton — owns the SQLite-backed mutable game state.
#
# DATA SPLIT
#   res://data/gb_godot.json  — IMMUTABLE map geometry/topology (MapData)
#   user://current.db              — LIVE working save (auto-resumes)
#   user://saves/slot*.db          — explicit checkpoints from the Save button
#
# Schema lives below as `_migrate()`. Schema version is recorded in the `meta`
# table; future versions add ALTERs gated on that value.

extends Node

const SCHEMA_VERSION := 3
const WORKING_DB := "user://current.db"
const SAVES_DIR  := "user://saves/"

# Design-data source-of-truth lookups. The actual values used to live as
# const dicts here; they've been moved to data/gb_design.json (loaded by
# the DesignData autoload). These accessors return the live design data,
# falling back to safe minimal defaults if the autoload hasn't loaded yet.

func _factions_by_duchy() -> Dictionary:
	if DesignData.loaded:
		return DesignData.factions_by_duchy
	# Minimal fallback so a missing design file doesn't crash autoload.
	return {"lancaster": "england", "wales": "wales", "scotland": "scotland"}


func _faction_seed() -> Array:
	if DesignData.loaded:
		return DesignData.faction_seed
	return [{"id": "england", "name": "England", "color_hex": "#c8102e", "treasury": 1000}]


func _fertility_by_duchy() -> Dictionary:
	if DesignData.loaded:
		return DesignData.fertility_by_duchy
	return {}


func _default_harvest_params() -> Array:
	if DesignData.loaded:
		return DesignData.default_harvest_params
	# Minimal flat distribution — keeps end_turn() functional in the
	# unlikely case that DesignData failed to load.
	return [
		{"season": 0, "mean": 0.5, "std_dev": 0.1, "min_val": 0.2, "max_val": 1.0, "description": "default"},
		{"season": 1, "mean": 0.5, "std_dev": 0.1, "min_val": 0.2, "max_val": 1.0, "description": "default"},
		{"season": 2, "mean": 0.5, "std_dev": 0.1, "min_val": 0.2, "max_val": 1.0, "description": "default"},
		{"season": 3, "mean": 0.5, "std_dev": 0.1, "min_val": 0.2, "max_val": 1.0, "description": "default"},
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

	# v3 — political layer: families, characters, holdings. Lord/earl/baron
	# strings from DesignData are parsed into Family + Character at seed
	# time; holdings link each region to its current head-of-family.
	db.query("""
		CREATE TABLE IF NOT EXISTS families (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			surname TEXT NOT NULL UNIQUE,
			prestige INTEGER NOT NULL DEFAULT 50,
			founder_turn INTEGER NOT NULL DEFAULT 0,
			notes TEXT
		);""")
	db.query("""
		CREATE TABLE IF NOT EXISTS characters (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			given_name TEXT NOT NULL,
			family_id INTEGER REFERENCES families(id),
			title TEXT,
			age INTEGER NOT NULL DEFAULT 30,
			gender TEXT NOT NULL DEFAULT 'male',
			alive INTEGER NOT NULL DEFAULT 1,
			martial INTEGER NOT NULL DEFAULT 5,
			diplomacy INTEGER NOT NULL DEFAULT 5,
			stewardship INTEGER NOT NULL DEFAULT 5,
			intrigue INTEGER NOT NULL DEFAULT 5,
			piety INTEGER NOT NULL DEFAULT 5,
			traits_json TEXT NOT NULL DEFAULT '[]'
		);""")
	db.query("""
		CREATE TABLE IF NOT EXISTS holdings (
			region_type TEXT NOT NULL,
			region_id TEXT NOT NULL,
			holder_character_id INTEGER REFERENCES characters(id),
			holder_family_id INTEGER REFERENCES families(id),
			updated_turn INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (region_type, region_id)
		);""")
	db.query("CREATE INDEX IF NOT EXISTS idx_characters_family ON characters(family_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_holdings_holder ON holdings(holder_character_id);")

	# Version-gated patches for older DBs.
	var prev_version: int = _read_schema_version()
	if prev_version < 2:
		_migrate_to_v2()
	if prev_version < 3:
		_migrate_to_v3()

	db.query_with_bindings(
		"INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?);",
		[str(SCHEMA_VERSION)]
	)

	# Heal-on-resume: an earlier v3 migration created the tables but didn't
	# seed (the first _migrate_to_v3 was a pass). Re-running here back-fills
	# those DBs; idempotent via _seed_political's holdings-count guard.
	_seed_political()


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
		for p in _default_harvest_params():
			db.query_with_bindings(
				"INSERT OR IGNORE INTO harvest_params(season, mean, std_dev, min_val, max_val, description) VALUES(?,?,?,?,?,?);",
				[p.season, p.mean, p.std_dev, p.min_val, p.max_val, p.description]
			)


# v2 → v3 upgrade. Tables already created by the CREATE TABLE IF NOT EXISTS
# block above; this step seeds the political layer for saves that came up
# from v2 without ever hitting new_game() (the seed normally runs there).
# _seed_political() is idempotent — it early-returns if holdings is non-empty.
func _migrate_to_v3() -> void:
	_seed_political()


# Populate factions + counties_state from MapData. INSERT OR IGNORE makes this
# safe to call on an existing seeded DB (it won't clobber treasuries etc).
#
# Per-county fertility is derived as FERTILITY_BY_DUCHY[duchy] + small Gaussian
# noise (σ=0.08), clamped to [0.4, 1.6]. Counties whose duchy isn't in the
# table fall back to 1.0.
func _seed() -> void:
	var factions_by_duchy: Dictionary = _factions_by_duchy()
	var fertility_by_duchy: Dictionary = _fertility_by_duchy()

	for f in _faction_seed():
		db.query_with_bindings(
			"INSERT OR IGNORE INTO factions(id, name, color_hex, treasury) VALUES(?,?,?,?);",
			[f.id, f.name, f.color_hex, f.treasury]
		)

	for cname in MapData.counties:
		var co: Dictionary = MapData.counties[cname]
		var duchy: String = co.get("duchy", "")
		var owner: String = factions_by_duchy.get(duchy, "england")
		var garrison: int = int(co.get("garrison", 0))
		var base_fertility: float = fertility_by_duchy.get(duchy, 1.0)
		var fertility: float = clampf(
			GaussianSystem.sample(base_fertility, 0.08),
			0.4, 1.6
		)
		db.query_with_bindings(
			"INSERT OR IGNORE INTO counties_state(county_id, owner_faction_id, garrison, fertility, updated_turn) VALUES(?,?,?,?,?);",
			[cname, owner, garrison, fertility, 0]
		)

	# Back-fill fertility on v1→v2 migrated rows that were left at the
	# default 1.0 — the duchy-derived value reads more meaningfully.
	for cname in MapData.counties:
		var co: Dictionary = MapData.counties[cname]
		var duchy: String = co.get("duchy", "")
		var base_fertility: float = fertility_by_duchy.get(duchy, 1.0)
		var fertility: float = clampf(
			GaussianSystem.sample(base_fertility, 0.08),
			0.4, 1.6
		)
		db.query_with_bindings(
			"UPDATE counties_state SET fertility = ? WHERE county_id = ? AND fertility = 1.0;",
			[fertility, cname]
		)

	# Political layer (v3): families, characters, holdings. Run once per
	# fresh game — INSERT OR IGNORE keeps it safe on reseed.
	_seed_political()

	if current_turn() == 0:
		advance_turn()


# Split a lord/earl/baron string from the design layer into (given, surname).
# Heuristics (best-effort — design strings vary):
#   "John de Lacy"         → ("John", "de Lacy")
#   "FitzAlan"             → ("",     "FitzAlan")     (only surname)
#   "Crown Direct"         → ("Crown","Direct")       (placeholder)
#   "Wm. de Beauchamp"     → ("Wm.",  "de Beauchamp")
#   "Llywelyn ap Gruffudd" → ("Llywelyn", "ap Gruffudd")
#   "Prince-Bishop"        → ("",     "Prince-Bishop") (titular)
# Strings containing parenthetical asides have those stripped first.
func _parse_lord_name(s: String) -> Dictionary:
	var t: String = s.strip_edges()
	# Strip "( ... )" trailing context like "Crown Direct (London)".
	var paren := t.find("(")
	if paren > 0:
		t = t.substr(0, paren).strip_edges()
	if t == "":
		return {"given": "", "surname": "Unknown"}
	var parts: PackedStringArray = t.split(" ", false)
	if parts.size() == 1:
		return {"given": "", "surname": parts[0]}
	# Otherwise: first token = given, the rest = surname.
	return {"given": parts[0], "surname": " ".join(parts.slice(1))}


# Get-or-create a family row by surname. Returns the family id.
func _ensure_family(surname: String) -> int:
	if surname == "":
		surname = "Unknown"
	db.query_with_bindings("SELECT id FROM families WHERE surname = ?;", [surname])
	if not db.query_result.is_empty():
		return int(db.query_result[0]["id"])
	db.query_with_bindings(
		"INSERT INTO families(surname, prestige, founder_turn) VALUES(?,?,?);",
		[surname, 50, 0]
	)
	return db.get_last_insert_rowid()


# Insert a character + return its id. Stats default to 5 (median 1..10).
# Designer can override later via DesignData hand-edits.
func _insert_character(given: String, family_id: int, title: String, age: int) -> int:
	db.query_with_bindings(
		"INSERT INTO characters(given_name, family_id, title, age) VALUES(?,?,?,?);",
		[given if given != "" else "Lord", family_id, title, max(18, age)]
	)
	return db.get_last_insert_rowid()


# Upsert a holding row linking a region to its current head-of-family.
func _set_holding(region_type: String, region_id: String, character_id: int, family_id: int) -> void:
	db.query_with_bindings(
		"INSERT OR REPLACE INTO holdings(region_type, region_id, holder_character_id, holder_family_id, updated_turn) VALUES(?,?,?,?,?);",
		[region_type, region_id, character_id, family_id, 0]
	)


# Build the political layer from DesignData strings + monarchs + per-LAD
# barony holders. Runs once on first new game; INSERT OR IGNORE / OR REPLACE
# semantics make it safe to re-run.
func _seed_political() -> void:
	if not DesignData.loaded:
		push_warning("GameState._seed_political: DesignData not loaded yet")
		return
	# Skip if we've already seeded (any holdings row exists).
	db.query("SELECT COUNT(*) AS c FROM holdings;")
	if int(db.query_result[0]["c"]) > 0:
		return

	# COUNTRIES — monarch per faction.
	for country in ["england", "wales", "scotland"]:
		var m: Dictionary = DesignData.monarchs.get(country, {})
		var sn: String = str(m.get("surname", country.capitalize()))
		var gn: String = str(m.get("given", ""))
		var fid: int = _ensure_family(sn)
		var cid: int = _insert_character(gn, fid, str(m.get("title", "Monarch")),
				int(m.get("age", 35)))
		_set_holding("country", country, cid, fid)

	# DUCHIES — each has a `lord` field in DesignData.duchies.
	for did in DesignData.duchies:
		var lord_str: String = str(DesignData.duchies[did].get("lord", ""))
		var parsed: Dictionary = _parse_lord_name(lord_str)
		var fid := _ensure_family(parsed.surname)
		var cid := _insert_character(parsed.given, fid, "Duke", 40)
		_set_holding("duchy", did, cid, fid)

	# COUNTIES — `earl` field in DesignData.counties.
	for cn in DesignData.counties:
		var earl_str: String = str(DesignData.counties[cn].get("earl", ""))
		var parsed: Dictionary = _parse_lord_name(earl_str)
		var fid := _ensure_family(parsed.surname)
		var cid := _insert_character(parsed.given, fid, "Earl", 35)
		_set_holding("county", cn, cid, fid)

	# BARONIES — every LAD got a deterministic baron entry from extract_design.py.
	for lad in DesignData.barony_holders:
		var h: Dictionary = DesignData.barony_holders[lad]
		var fid := _ensure_family(str(h.get("surname", "of " + lad)))
		var cid := _insert_character(str(h.get("given", "")), fid,
				str(h.get("title", "Baron")), int(h.get("age", 30)))
		_set_holding("barony", lad, cid, fid)

	print("GameState: seeded political layer — %d holdings" % _count_holdings())


func _count_holdings() -> int:
	db.query("SELECT COUNT(*) AS c FROM holdings;")
	if db.query_result.is_empty():
		return 0
	return int(db.query_result[0]["c"])


# Public: look up the head-of-family currently holding a region.
#
# Args:
#   region_type (String): "country" | "duchy" | "county" | "barony".
#   region_id (String): country id, duchy id, county name, or LAD13CD.
# Returns:
#   Dictionary: {given_name, surname, title, age, character_id, family_id,
#                prestige} or {} if no holder is recorded.
func holder_of(region_type: String, region_id: String) -> Dictionary:
	db.query_with_bindings("""
		SELECT c.id AS character_id, c.given_name, c.title, c.age,
		       f.id AS family_id, f.surname, f.prestige
		FROM holdings h
		JOIN characters c ON c.id = h.holder_character_id
		JOIN families   f ON f.id = h.holder_family_id
		WHERE h.region_type = ? AND h.region_id = ?
		LIMIT 1;""",
		[region_type, region_id]
	)
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()
