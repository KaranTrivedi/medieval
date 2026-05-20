# GameState.gd
# Autoload singleton — owns the SQLite-backed mutable game state.
#
# DATA SPLIT
#   res://data/gb_godot.json   — IMMUTABLE map geometry/topology (MapData)
#   res://data/gb_design.json  — IMMUTABLE design layer (DesignData)
#   user://current.db          — LIVE working save (auto-resumes)
#   user://saves/slot*.db      — explicit checkpoints from the Save button
#
# SCHEMA
# Game-state tables: factions, counties_state, turns, harvest_params.
# Political layer:   families, characters, holdings, relationships.
# All created in one shot in `_create_schema()` — no migration scaffolding,
# we're pre-1.0 and breaking changes are fine. If the schema changes here,
# delete user://current.db (or let `new_game()` overwrite it).

extends Node

const WORKING_DB := "user://current.db"
const SAVES_DIR  := "user://saves/"

# Design-data accessors with safe fallbacks. The actual values come from
# DesignData (autoload that loads data/gb_design.json before us).

func _factions_by_duchy() -> Dictionary:
	if DesignData.loaded:
		return DesignData.factions_by_duchy
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
	return [
		{"season": 0, "mean": 0.5, "std_dev": 0.1, "min_val": 0.2, "max_val": 1.0, "description": "default"},
		{"season": 1, "mean": 0.5, "std_dev": 0.1, "min_val": 0.2, "max_val": 1.0, "description": "default"},
		{"season": 2, "mean": 0.5, "std_dev": 0.1, "min_val": 0.2, "max_val": 1.0, "description": "default"},
		{"season": 3, "mean": 0.5, "std_dev": 0.1, "min_val": 0.2, "max_val": 1.0, "description": "default"},
	]

var db: SQLite = null
var player_faction_id: String = "england"

signal state_changed


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVES_DIR)
	if FileAccess.file_exists(WORKING_DB):
		_open(WORKING_DB)
		_create_schema()
		print("GameState: resumed working save at ", WORKING_DB,
				" (turn=", current_turn(), ")")
	else:
		new_game("england")


# Start a fresh game.
func new_game(player_id: String) -> void:
	player_faction_id = player_id
	if db != null:
		db.close_db()
		db = null
	if FileAccess.file_exists(WORKING_DB):
		DirAccess.remove_absolute(WORKING_DB)
	_open(WORKING_DB)
	_create_schema()
	if not MapData.is_loaded:
		await MapData.map_loaded
	_seed()
	print("GameState: new game started for ", player_id,
			" — turn=", current_turn())
	state_changed.emit()


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
	_create_schema()
	state_changed.emit()
	return true


func save_to(path: String) -> bool:
	if db == null:
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	db.close_db()
	var err := DirAccess.copy_absolute(WORKING_DB, path)
	db.open_db()
	if err != OK:
		push_error("GameState.save_to: copy failed (err=%d) to %s" % [err, path])
		return false
	print("GameState: saved to ", path)
	return true


# ── QUERIES ───────────────────────────────────────────────────────────────────

func current_turn() -> int:
	db.query("SELECT MAX(turn_number) AS t FROM turns;")
	if db.query_result.is_empty() or db.query_result[0]["t"] == null:
		return 0
	return int(db.query_result[0]["t"])


# Run one full end-of-turn step for the player faction. See the previous
# version of this file in git history for the per-line walk-through.
func end_turn() -> Dictionary:
	const SEASON_NAMES := ["Spring", "Summer", "Autumn", "Winter"]
	var summary: Dictionary = {"counties": [], "total_income": 0}

	var cur_turn: int = maxi(current_turn(), 1)
	var season_idx: int = (cur_turn - 1) % 4
	var params: Dictionary = get_harvest_params(season_idx)

	db.query_with_bindings(
		"SELECT county_id, fertility FROM counties_state WHERE owner_faction_id = ?;",
		[player_faction_id]
	)
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
		db.query_with_bindings(
			"UPDATE factions SET treasury = treasury + ? WHERE id = ?;",
			[total, player_faction_id]
		)

	summary.turn = advance_turn()
	summary.treasury = int(faction(player_faction_id).get("treasury", 0))
	return summary


func get_harvest_params(season: int) -> Dictionary:
	db.query_with_bindings("SELECT * FROM harvest_params WHERE season = ?;", [season])
	if db.query_result.is_empty():
		push_warning("harvest_params row missing for season %d — using fallback" % season)
		return {"mean": 1.0, "std_dev": 0.4, "min_val": 0.167, "max_val": 2.0,
				"description": "(fallback)"}
	return db.query_result[0].duplicate()


func set_harvest_params(season: int, mean: float, std_dev: float,
		min_val: float, max_val: float, description: String) -> void:
	db.query_with_bindings(
		"INSERT OR REPLACE INTO harvest_params(season, mean, std_dev, min_val, max_val, description) VALUES(?,?,?,?,?,?);",
		[season, mean, std_dev, min_val, max_val, description]
	)
	state_changed.emit()


func advance_turn() -> int:
	var prev := current_turn()
	var next := prev + 1
	var season := prev % 4
	var year := 1247 + int(prev / 4)
	db.query_with_bindings(
		"INSERT INTO turns(turn_number, year, season, active_faction_id, processed_at) VALUES(?,?,?,?,?);",
		[next, year, season, player_faction_id, Time.get_datetime_string_from_system()]
	)
	state_changed.emit()
	return next


func county_state(county_id: String) -> Dictionary:
	db.query_with_bindings("SELECT * FROM counties_state WHERE county_id = ?;", [county_id])
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()


func set_county_state(county_id: String, patch: Dictionary) -> void:
	if patch.is_empty():
		return
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


func faction(id: String) -> Dictionary:
	db.query_with_bindings("SELECT * FROM factions WHERE id = ?;", [id])
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()


func adjust_treasury(faction_id: String, delta: int) -> int:
	db.query_with_bindings(
		"UPDATE factions SET treasury = treasury + ? WHERE id = ?;",
		[delta, faction_id]
	)
	state_changed.emit()
	var f := faction(faction_id)
	return int(f.get("treasury", 0))


# ── POLITICAL LAYER (read API) ────────────────────────────────────────────────

# Look up the head-of-family currently holding a region.
#
# Args:
#   region_type (String): "country" | "duchy" | "county" | "barony".
#   region_id (String): country id, duchy id, county name, or LAD13CD.
# Returns:
#   Dictionary: {given_name, surname, title, age, character_id, family_id,
#                prestige} or {} if no holder is recorded.
func holder_of(region_type: String, region_id: String) -> Dictionary:
	db.query_with_bindings("""
		SELECT c.id AS character_id, c.given_name, c.title, c.age, c.gender, c.alive,
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


# Full character record + family info.
#
# Args:
#   character_id (int): characters.id primary key.
# Returns:
#   Dictionary with character + family columns flattened, or {} if not found.
func character(character_id: int) -> Dictionary:
	db.query_with_bindings("""
		SELECT c.id AS character_id, c.given_name, c.title, c.age, c.gender, c.alive,
		       c.martial, c.diplomacy, c.stewardship, c.intrigue, c.piety,
		       c.traits_json,
		       f.id AS family_id, f.surname, f.prestige
		FROM characters c
		LEFT JOIN families f ON f.id = c.family_id
		WHERE c.id = ?
		LIMIT 1;""",
		[character_id]
	)
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()


# Read a family row.
func family(family_id: int) -> Dictionary:
	db.query_with_bindings("SELECT * FROM families WHERE id = ?;", [family_id])
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()


# Walk relationships for one character. Returns rows shaped as
#   {kind, other: {character_id, given_name, surname, ...}}
# Kinds: "spouse", "parent", "child", "sibling".
func relations_of(character_id: int) -> Array:
	db.query_with_bindings("""
		SELECT r.kind, c.id AS character_id, c.given_name, c.title, c.age, c.gender, c.alive,
		       f.id AS family_id, f.surname
		FROM relationships r
		JOIN characters c ON c.id = r.related_id
		LEFT JOIN families f ON f.id = c.family_id
		WHERE r.character_id = ?
		ORDER BY CASE r.kind
			WHEN 'parent' THEN 0
			WHEN 'spouse' THEN 1
			WHEN 'sibling' THEN 2
			WHEN 'child' THEN 3
			ELSE 9
		END, c.age DESC;""",
		[character_id]
	)
	var out: Array = []
	for row in db.query_result:
		out.append({
			"kind": str(row["kind"]),
			"other": {
				"character_id": int(row["character_id"]),
				"given_name": str(row["given_name"]),
				"surname": str(row["surname"]),
				"title": str(row["title"]),
				"age": int(row["age"]),
				"gender": str(row["gender"]),
				"alive": int(row["alive"]) != 0,
				"family_id": int(row["family_id"]) if row["family_id"] != null else 0,
			}
		})
	return out


# Regions currently held by a character.
func holdings_of(character_id: int) -> Array:
	db.query_with_bindings("""
		SELECT region_type, region_id FROM holdings
		WHERE holder_character_id = ?
		ORDER BY CASE region_type
			WHEN 'country' THEN 0 WHEN 'duchy' THEN 1
			WHEN 'county' THEN 2 WHEN 'barony' THEN 3
			ELSE 9 END, region_id;""",
		[character_id]
	)
	var out: Array = []
	for row in db.query_result:
		out.append({
			"region_type": str(row["region_type"]),
			"region_id": str(row["region_id"]),
		})
	return out


# ── INTERNAL ──────────────────────────────────────────────────────────────────

func _open(path: String) -> void:
	db = SQLite.new()
	db.path = path
	db.foreign_keys = true
	db.open_db()


# Create the full schema. Idempotent (CREATE TABLE IF NOT EXISTS).
func _create_schema() -> void:
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

	# Political layer.
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
	db.query("""
		CREATE TABLE IF NOT EXISTS relationships (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			character_id INTEGER NOT NULL REFERENCES characters(id),
			related_id INTEGER NOT NULL REFERENCES characters(id),
			kind TEXT NOT NULL,
			UNIQUE(character_id, related_id, kind)
		);""")
	db.query("CREATE INDEX IF NOT EXISTS idx_characters_family ON characters(family_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_holdings_holder ON holdings(holder_character_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_rel_character ON relationships(character_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_rel_related ON relationships(related_id);")


# Seed the full game state from MapData + DesignData. INSERT OR IGNORE makes
# this safe to re-run; the political-seed step uses its own emptiness guard.
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

	# Seed harvest_params from DesignData.
	for p in _default_harvest_params():
		db.query_with_bindings(
			"INSERT OR IGNORE INTO harvest_params(season, mean, std_dev, min_val, max_val, description) VALUES(?,?,?,?,?,?);",
			[p.season, p.mean, p.std_dev, p.min_val, p.max_val, p.description]
		)

	_seed_political()

	if current_turn() == 0:
		advance_turn()


# Helpers used by the seed.

func _ensure_family(surname: String, prestige: int = 50) -> int:
	if surname.is_empty():
		surname = "Unknown"
	db.query_with_bindings("SELECT id FROM families WHERE surname = ?;", [surname])
	if not db.query_result.is_empty():
		return int(db.query_result[0]["id"])
	db.query_with_bindings(
		"INSERT INTO families(surname, prestige, founder_turn) VALUES(?,?,0);",
		[surname, prestige]
	)
	return db.get_last_insert_rowid()


func _insert_character(given: String, family_id: int, title: String, age: int,
		gender: String = "male", alive: bool = true) -> int:
	if given.is_empty():
		given = "Anon"
	db.query_with_bindings(
		"INSERT INTO characters(given_name, family_id, title, age, gender, alive) VALUES(?,?,?,?,?,?);",
		[given, family_id, title, max(0, age), gender, 1 if alive else 0]
	)
	return db.get_last_insert_rowid()


func _set_holding(region_type: String, region_id: String, character_id: int, family_id: int) -> void:
	db.query_with_bindings(
		"INSERT OR REPLACE INTO holdings(region_type, region_id, holder_character_id, holder_family_id, updated_turn) VALUES(?,?,?,?,?);",
		[region_type, region_id, character_id, family_id, 0]
	)


func _link(a_id: int, b_id: int, kind: String) -> void:
	db.query_with_bindings(
		"INSERT OR IGNORE INTO relationships(character_id, related_id, kind) VALUES(?,?,?);",
		[a_id, b_id, kind]
	)


# Two-way insertion for symmetric or paired-inverse relations.
#   spouse  → both directions, both "spouse"
#   sibling → both directions, both "sibling"
#   parent  → A is parent of B, so insert (A, B, "child") and (B, A, "parent")
func _link_pair(a_id: int, b_id: int, kind_a_to_b: String) -> void:
	match kind_a_to_b:
		"spouse":
			_link(a_id, b_id, "spouse")
			_link(b_id, a_id, "spouse")
		"sibling":
			_link(a_id, b_id, "sibling")
			_link(b_id, a_id, "sibling")
		"child":
			# A has child B → B has parent A
			_link(a_id, b_id, "child")
			_link(b_id, a_id, "parent")
		"parent":
			_link(a_id, b_id, "parent")
			_link(b_id, a_id, "child")


# Deterministic random helper based on a string + index. djb2-ish; we don't
# need crypto here, just stability across runs so the same holder always gets
# the same generated family.
func _hash_int(seed_str: String, idx: int = 0) -> int:
	var s := seed_str + ":" + str(idx)
	var h: int = 5381
	for i in range(s.length()):
		h = ((h << 5) + h + s.unicode_at(i)) & 0x7FFFFFFF
	return h


# Build the political layer end-to-end from DesignData.
# Each holder gets:
#   - a Family (created lazily by surname)
#   - a Character record + Holding row
#   - a spouse (different family), 1–3 children (holder's family), 1 deceased parent
#   - 0–1 sibling (50/50)
# Idempotent — early-returns when holdings is non-empty.
func _seed_political() -> void:
	if not DesignData.loaded:
		push_warning("GameState._seed_political: DesignData not loaded yet")
		return
	db.query("SELECT COUNT(*) AS c FROM holdings;")
	if int(db.query_result[0]["c"]) > 0:
		return

	# COUNTRIES — monarch per faction.
	for country in ["england", "wales", "scotland"]:
		var m: Dictionary = DesignData.monarchs.get(country, {})
		var sn: String = str(m.get("surname", country.capitalize()))
		var gn: String = str(m.get("given", "Anon"))
		var fid: int = _ensure_family(sn, 100)
		var cid: int = _insert_character(gn, fid, str(m.get("title", "Monarch")),
				int(m.get("age", 35)), str(m.get("gender", "male")))
		_set_holding("country", country, cid, fid)
		_seed_close_family(cid, sn, str(m.get("gender", "male")), int(m.get("age", 35)))

	# DUCHIES.
	for did in DesignData.duchies:
		var lord: Dictionary = _holder_dict(DesignData.duchies[did].get("lord"))
		var fid := _ensure_family(lord.surname, 75)
		var cid := _insert_character(lord.given, fid, "Duke", lord.age, lord.gender)
		_set_holding("duchy", did, cid, fid)
		_seed_close_family(cid, lord.surname, lord.gender, lord.age)

	# COUNTIES.
	for cn in DesignData.counties:
		var earl: Dictionary = _holder_dict(DesignData.counties[cn].get("earl"))
		var fid := _ensure_family(earl.surname, 60)
		var cid := _insert_character(earl.given, fid, "Earl", earl.age, earl.gender)
		_set_holding("county", cn, cid, fid)
		_seed_close_family(cid, earl.surname, earl.gender, earl.age)

	# BARONIES.
	for lad in DesignData.barony_holders:
		var h: Dictionary = DesignData.barony_holders[lad]
		var bh: Dictionary = _holder_dict(h)
		var fid := _ensure_family(bh.surname, 50)
		var cid := _insert_character(bh.given, fid, bh.get("title", "Baron"),
				bh.age, bh.gender)
		_set_holding("barony", lad, cid, fid)
		_seed_close_family(cid, bh.surname, bh.gender, bh.age)

	print("GameState: seeded political layer — %d holdings, %d characters, %d families, %d relationships" % [
		_count("holdings"), _count("characters"), _count("families"), _count("relationships")
	])


# Normalise a holder field that might be either a dict ({given, surname,...})
# or a legacy string ("John de Lacy") into a consistent dict shape.
func _holder_dict(raw) -> Dictionary:
	var out: Dictionary = {
		"given": "Anon", "surname": "Unknown", "title": "Lord",
		"age": 30, "gender": "male",
	}
	if raw is Dictionary:
		for k in raw.keys():
			out[k] = raw[k]
		out["given"] = str(out.get("given", "Anon"))
		out["surname"] = str(out.get("surname", "Unknown"))
		out["title"] = str(out.get("title", "Lord"))
		out["gender"] = str(out.get("gender", "male"))
		out["age"] = int(out.get("age", 30))
	elif raw is String and not (raw as String).is_empty():
		var parts: PackedStringArray = (raw as String).strip_edges().split(" ", false)
		if parts.size() == 1:
			out["surname"] = parts[0]
		elif parts.size() >= 2:
			out["given"] = parts[0]
			out["surname"] = " ".join(parts.slice(1))
	return out


# Generate spouse + children + parent + maybe sibling for `holder_id`.
# Names sampled deterministically from DesignData.name_pools by hashing the
# holder's surname + role, so the same holder always gets the same family.
#
# Args:
#   holder_id (int): characters.id of the head-of-family.
#   surname (String): holder's surname — used for kids and dad (same family).
#   gender (String): "male"|"female" — spouse picks the opposite.
#   age (int): holder's age — drives children/parent ages.
func _seed_close_family(holder_id: int, surname: String, gender: String, age: int) -> void:
	var pools: Dictionary = DesignData.name_pools if "name_pools" in DesignData else {}
	if pools.is_empty():
		return
	var male_pool_by_country: Dictionary = pools.get("male", {})
	var female_pool_by_country: Dictionary = pools.get("female", {})
	var surname_pool_by_country: Dictionary = pools.get("surnames", {})
	# Pick a name region by surname pattern.
	var region: String = _region_for_surname(surname)
	var male_names: Array = male_pool_by_country.get(region, male_pool_by_country.get("E", []))
	var female_names: Array = female_pool_by_country.get(region, female_pool_by_country.get("E", []))
	var foreign_surnames: Array = surname_pool_by_country.get(region, surname_pool_by_country.get("E", []))

	var seed_key := surname + "#" + str(holder_id)

	# ── SPOUSE ──
	var spouse_gender: String = "female" if gender == "male" else "male"
	var spouse_pool: Array = female_names if spouse_gender == "female" else male_names
	var spouse_given: String = spouse_pool[_hash_int(seed_key, 1) % max(1, spouse_pool.size())]
	# Spouse keeps a maiden surname from a DIFFERENT family — pick from the pool.
	var spouse_surname: String = foreign_surnames[_hash_int(seed_key, 2) % max(1, foreign_surnames.size())]
	# In case of accidental match with holder's surname, nudge.
	if spouse_surname == surname:
		spouse_surname = foreign_surnames[(_hash_int(seed_key, 2) + 1) % max(1, foreign_surnames.size())]
	var spouse_age: int = clampi(age + ((_hash_int(seed_key, 3) % 11) - 5), 18, 75)
	var spouse_family_id: int = _ensure_family(spouse_surname, 45)
	var spouse_id: int = _insert_character(spouse_given, spouse_family_id,
			"Lady" if spouse_gender == "female" else "Lord",
			spouse_age, spouse_gender)
	_link_pair(holder_id, spouse_id, "spouse")

	# ── PARENT (deceased, holder's father — anchors patriline) ──
	var dad_given: String = male_names[_hash_int(seed_key, 4) % max(1, male_names.size())]
	var dad_family_id: int = _ensure_family(surname, 50)
	var dad_age: int = age + 25 + (_hash_int(seed_key, 5) % 10)
	var dad_id: int = _insert_character(dad_given, dad_family_id, "Lord", dad_age, "male", false)
	_link_pair(dad_id, holder_id, "child")  # dad is parent of holder

	# ── CHILDREN ──
	# 1..3 children. Each shares holder's family. Eldest age = age - 22 down to 5.
	var child_count: int = 1 + (_hash_int(seed_key, 6) % 3)
	var holder_family_id: int = _ensure_family(surname)
	var youngest_age: int = max(2, age - 25)
	for i in range(child_count):
		var child_gender: String = "male" if (_hash_int(seed_key, 10 + i) % 2 == 0) else "female"
		var pool: Array = male_names if child_gender == "male" else female_names
		var cgiven: String = pool[_hash_int(seed_key, 20 + i) % max(1, pool.size())]
		var cage: int = clampi(youngest_age + i * 3, 2, max(3, age - 18))
		var title: String = "Heir" if i == 0 and child_gender == "male" else (
				"Lord" if child_gender == "male" else "Lady")
		var cid: int = _insert_character(cgiven, holder_family_id, title, cage, child_gender)
		_link_pair(holder_id, cid, "child")
		# Spouse is also a parent.
		_link_pair(spouse_id, cid, "child")

	# ── SIBLING (50%) ──
	if (_hash_int(seed_key, 30) % 2) == 0:
		var sib_gender: String = "male" if (_hash_int(seed_key, 31) % 2 == 0) else "female"
		var sib_pool: Array = male_names if sib_gender == "male" else female_names
		var sib_given: String = sib_pool[_hash_int(seed_key, 32) % max(1, sib_pool.size())]
		var sib_age: int = clampi(age + ((_hash_int(seed_key, 33) % 13) - 6), 16, 70)
		var sib_id: int = _insert_character(sib_given, holder_family_id, "Lord" if sib_gender == "male" else "Lady", sib_age, sib_gender)
		_link_pair(holder_id, sib_id, "sibling")
		# Same dad too.
		_link_pair(dad_id, sib_id, "child")


# Best-guess country letter from a surname so we sample given-names from the
# matching pool. "ap X" → Welsh, "Mac/Mc/of X (Scot.)" → Scottish, else English.
func _region_for_surname(surname: String) -> String:
	var s := surname.to_lower()
	if s.begins_with("ap ") or s.begins_with("ferch "):
		return "W"
	if s.begins_with("mac") or s.begins_with("mc"):
		return "S"
	# Some Scottish surnames are bare clan names — match the ones we know.
	for clan in ["comyn", "bruce", "stewart", "fraser", "graham", "lindsay",
			"sinclair", "sutherland", "macduff", "campbell", "douglas",
			"hamilton", "ramsay", "maxwell", "wallace", "dunkeld", "balliol",
			"of ross", "of lorn", "of lennox", "of mar", "of buchan",
			"of strathearn", "of atholl"]:
		if s == clan or s.ends_with(clan):
			return "S"
	return "E"


func _count(table: String) -> int:
	db.query("SELECT COUNT(*) AS c FROM %s;" % table)
	if db.query_result.is_empty():
		return 0
	return int(db.query_result[0]["c"])
