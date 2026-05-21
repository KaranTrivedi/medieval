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
		# Heal-on-resume passes — both are idempotent so they're safe to
		# run every load.
		_ensure_offices_seeded()
		_ensure_economy_schema()
		_ensure_ambitions_seeded()
		_ensure_retinues_seeded()
		print("GameState: resumed working save at ", WORKING_DB,
				" (turn=", current_turn(), ")")
	else:
		new_game("england")


# Back-fill ambitions for any pre-existing alive character that lacks one.
# Brand-new characters get an ambition in _insert_character; this catches
# saves that predate the feature so the player isn't stuck with a world
# full of motivation-less NPCs.
func _ensure_ambitions_seeded() -> void:
	db.query("""
		SELECT c.id FROM characters c
		LEFT JOIN character_ambitions a ON a.character_id = c.id
		WHERE c.alive = 1 AND a.id IS NULL;""")
	var ids: Array = []
	for row in db.query_result:
		ids.append(int(row["id"]))
	if ids.is_empty():
		return
	db.query("BEGIN;")
	for cid in ids:
		_generate_ambition(cid)
	db.query("COMMIT;")
	print("GameState: back-filled %d character ambitions" % ids.size())


# If the offices table is empty but we have country-tier holdings, seed the
# initial office appointments so resumed saves match fresh-game state.
# Offices are now NEVER auto-filled — appointments are a lord's prerogative.
# This sweep removes any rows left over from earlier builds that auto-seeded
# courtiers + wipes legacy office_key values that no longer exist (e.g. the
# old "steward" at country tier, now "treasurer"). Safe to run every load.
func _ensure_offices_seeded() -> void:
	# Offices are now NEVER auto-filled — appointment is a lord's prerogative.
	# Older builds seeded the table either with courtier characters or with
	# the monarch's relatives; both should be wiped exactly ONCE so the
	# player can re-appoint freely without our heal-on-resume stomping
	# subsequent picks. The sentinel lives in SQLite's free `PRAGMA
	# user_version` — no extra schema needed.
	#
	#   user_version = 0 → fresh DB, or pre-sweep build → do the wipe + bump
	#   user_version ≥ 1 → sweep already done → no-op
	db.query("PRAGMA user_version;")
	var sentinel: int = 0
	if not db.query_result.is_empty():
		sentinel = int(db.query_result[0].values()[0])
	if sentinel >= 1:
		return
	var before: int = _count("offices")
	db.query("DELETE FROM offices;")
	db.query("PRAGMA user_version = 1;")
	if before > 0:
		print("GameState: cleared %d legacy office rows (one-time sweep)" % before)


# Migration step 2: bring up the per-character economy (personal_treasury
# column + retinues table). user_version sentinel is bumped 1 → 2 once the
# column has been ALTERed onto pre-existing saves. Fresh DBs already get
# both via _create_schema, so they just bump the sentinel without ALTERing.
func _ensure_economy_schema() -> void:
	db.query("PRAGMA user_version;")
	var sentinel: int = 0
	if not db.query_result.is_empty():
		sentinel = int(db.query_result[0].values()[0])
	if sentinel >= 2:
		return
	# Detect whether the column is already present (fresh DBs) before ALTER.
	# ALTER TABLE ... ADD COLUMN errors if the column already exists, which
	# would otherwise abort the rest of the migration on a clean install.
	db.query("PRAGMA table_info(characters);")
	var has_col: bool = false
	for r in db.query_result:
		if str(r.get("name", "")) == "personal_treasury":
			has_col = true
			break
	if not has_col:
		db.query("ALTER TABLE characters ADD COLUMN personal_treasury INTEGER NOT NULL DEFAULT 0;")
		print("GameState: added characters.personal_treasury column (migration v1→v2)")
	db.query("PRAGMA user_version = 2;")


# Make sure every living character has a retinue row. Idempotent via the
# PRIMARY KEY on retinues.character_id. Default counts are scaled by the
# character's highest-held tier so a monarch starts with a real host while
# a landless cousin starts with nothing to maintain.
func _ensure_retinues_seeded() -> void:
	db.query("""
		SELECT id, family_id FROM characters
		WHERE alive = 1 AND id NOT IN (SELECT character_id FROM retinues);""")
	if db.query_result.is_empty():
		return
	var to_seed: Array = []
	for r in db.query_result:
		to_seed.append({"id": int(r["id"])})
	for c in to_seed:
		var cid: int = int(c.id)
		var counts: Dictionary = _default_retinue_for(cid)
		db.query_with_bindings("""
			INSERT OR IGNORE INTO retinues(character_id, foot, archers, cavalry, levy)
			VALUES(?,?,?,?,?);""",
			[cid, int(counts.foot), int(counts.archers),
			 int(counts.cavalry), int(counts.levy)]
		)
	print("GameState: seeded retinues for %d characters" % to_seed.size())


# Compute a starting retinue for a character based on the highest tier they
# personally hold. Landless characters get nothing — they're courtiers, not
# warlords. Tier counts are deliberately modest so upkeep stays affordable
# against the freshly bumped baseline incomes.
func _default_retinue_for(character_id: int) -> Dictionary:
	var rank: int = NO_HOLDING_TIER
	for h in holdings_of(character_id):
		var r: int = int(TIER_RANK.get(str(h.region_type), NO_HOLDING_TIER))
		if r < rank:
			rank = r
	match rank:
		0: return {"foot": 200, "archers": 50, "cavalry": 25, "levy": 10}
		1: return {"foot": 60,  "archers": 20, "cavalry": 8,  "levy": 5}
		2: return {"foot": 25,  "archers": 8,  "cavalry": 3,  "levy": 3}
		3: return {"foot": 8,   "archers": 3,  "cavalry": 1,  "levy": 2}
	return {"foot": 0, "archers": 0, "cavalry": 0, "levy": 0}


# Per-unit gold cost paid every turn out of personal_treasury.
const UPKEEP_PER_UNIT := {
	"foot": 1,
	"archers": 2,
	"cavalry": 4,
	"levy": 1,
}


# Read a character's retinue row + computed upkeep. Returns a uniform dict
# even when no row exists yet, so callers don't have to special-case the
# zero state.
#
# Args:
#   character_id (int).
# Returns:
#   {foot, archers, cavalry, levy, total, upkeep}
func retinue_of(character_id: int) -> Dictionary:
	if character_id <= 0:
		return {"foot": 0, "archers": 0, "cavalry": 0, "levy": 0, "total": 0, "upkeep": 0}
	db.query_with_bindings(
		"SELECT foot, archers, cavalry, levy FROM retinues WHERE character_id = ?;",
		[character_id]
	)
	var foot := 0; var archers := 0; var cav := 0; var levy := 0
	if not db.query_result.is_empty():
		var row: Dictionary = db.query_result[0]
		foot = int(row.get("foot", 0))
		archers = int(row.get("archers", 0))
		cav = int(row.get("cavalry", 0))
		levy = int(row.get("levy", 0))
	var upkeep: int = (
		foot * int(UPKEEP_PER_UNIT.foot)
		+ archers * int(UPKEEP_PER_UNIT.archers)
		+ cav * int(UPKEEP_PER_UNIT.cavalry)
		+ levy * int(UPKEEP_PER_UNIT.levy)
	)
	return {
		"foot": foot, "archers": archers, "cavalry": cav, "levy": levy,
		"total": foot + archers + cav + levy,
		"upkeep": upkeep,
	}


# Per-character end-of-turn economy. Each landed character takes a 25%
# personal cut from the gross income of every holding they own (representing
# manorial rents that don't flow to the crown), then pays retinue upkeep
# out of personal_treasury. Treasury can go negative — a deficit signals
# the lord is in arrears, which future systems can turn into desertion or
# unrest events.
#
# Returns:
#   Dictionary: {ticks: int} — number of characters processed.
func _advance_personal_economy() -> Dictionary:
	var ticks: int = 0
	# Pull every alive character with at least one holding in a single query
	# so we don't pay the SELECT cost per-character.
	db.query("""
		SELECT DISTINCT c.id AS character_id
		FROM characters c
		JOIN holdings h ON h.holder_character_id = c.id
		WHERE c.alive = 1;""")
	var ids: Array = []
	for r in db.query_result:
		ids.append(int(r["character_id"]))
	for cid in ids:
		var income: int = _personal_income_of(cid)
		var ret: Dictionary = retinue_of(cid)
		var net: int = income - int(ret.upkeep)
		if net != 0:
			db.query_with_bindings(
				"UPDATE characters SET personal_treasury = personal_treasury + ? WHERE id = ?;",
				[net, cid]
			)
		ticks += 1
	return {"ticks": ticks}


# 25% private-purse share of the gross income of every holding the character
# owns. Income is read from MapData at the county level — barony shares are
# the parent county's income divided across its baronies, since per-barony
# income data isn't authoritative yet.
func _personal_income_of(character_id: int) -> int:
	const SHARE_NUM := 25
	const SHARE_DEN := 100
	var gross: int = 0
	for h in holdings_of(character_id):
		var rt: String = str(h.region_type)
		var rid: String = str(h.region_id)
		match rt:
			"country":
				gross += int(MapData.aggregate_country(rid).get("total_income", 0))
			"duchy":
				gross += int(MapData.aggregate_duchy(rid).get("total_income", 0))
			"county":
				gross += int(MapData.get_county(rid).get("income", 0))
			"barony":
				# Barony income = its share of the parent county's income.
				var county_name: String = ""
				for cn in MapData.counties:
					for b in MapData.counties[cn].get("baronies", []):
						if str(b.get("id", "")) == rid:
							county_name = cn
							break
					if county_name != "":
						break
				if county_name != "":
					var co: Dictionary = MapData.get_county(county_name)
					var n: int = max(int(co.get("baronies", []).size()), 1)
					@warning_ignore("integer_division")
					gross += int(co.get("income", 0)) / n
	@warning_ignore("integer_division")
	return gross * SHARE_NUM / SHARE_DEN


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
	# Wrap the seed in a single SQLite transaction. Without this, every
	# INSERT issues its own commit, which on Windows can take 5-30 ms per
	# statement and turns the 3000-row seed into multi-second wall time.
	# A single transaction collapses that to a few hundred milliseconds.
	var seed_started_us: int = Time.get_ticks_usec()
	db.query("BEGIN;")
	_seed()
	# Mark a new DB as already-migrated and seed retinues for the freshly
	# created characters so the personal economy starts ticking immediately.
	db.query("PRAGMA user_version = 2;")
	_ensure_retinues_seeded()
	db.query("COMMIT;")
	@warning_ignore("integer_division")
	var seed_ms: int = (Time.get_ticks_usec() - seed_started_us) / 1000
	print("GameState: new game started for ", player_id,
			" — turn=", current_turn(), " (seed %d ms)" % seed_ms)
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
	# Older save files may predate the personal-treasury column + retinues
	# table — run the same idempotent migrations the resume path uses so
	# loaded saves come up to current schema.
	_ensure_offices_seeded()
	_ensure_economy_schema()
	_ensure_ambitions_seeded()
	_ensure_retinues_seeded()
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


# In-game year derived from the turn number. Each year = 4 turns; the game
# starts in Spring 1247 on turn 1.
func current_year() -> int:
	@warning_ignore("integer_division")
	return 1247 + max(current_turn() - 1, 0) / 4


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
	@warning_ignore("integer_division")
	var year := 1247 + prev / 4   # 4 seasons per year
	db.query_with_bindings(
		"INSERT INTO turns(turn_number, year, season, active_faction_id, processed_at) VALUES(?,?,?,?,?);",
		[next, year, season, player_faction_id, Time.get_datetime_string_from_system()]
	)
	# Lifecycle tick — fires once per in-game year, on the Spring transition.
	# Turn 1 is the game-start Spring; we don't age anyone there. Subsequent
	# Springs (turn 5, 9, 13, …) bump every alive character by one year and
	# resolve births, comings-of-age, marriages, and deaths.
	if next > 1 and (next - 1) % 4 == 0:
		_advance_lifecycle(year)
	# Personal economy ticks EVERY turn (not just the yearly transition) so
	# upkeep bites continuously — gives the player a regular cash-flow rhythm
	# rather than a once-a-year shock.
	_advance_personal_economy()
	state_changed.emit()
	return next


# ── LIFECYCLE ─────────────────────────────────────────────────────────────────
# Yearly tick. Ages every alive character by one year, then resolves deaths,
# comings-of-age, and marriage matches. Called from advance_turn() on the
# Spring transition (so once per simulated year).
#
# Args:
#   year (int): the new year just rolled into.
# Returns: void
func _advance_lifecycle(year: int) -> void:
	# 1. Age everyone alive.
	db.query("UPDATE characters SET age = age + 1 WHERE alive = 1;")

	# 2. Coming-of-age events at exactly 16. (We log when they cross the line.)
	db.query("SELECT id FROM characters WHERE alive = 1 AND age = 16;")
	for row in db.query_result:
		_log_lifecycle(int(row["id"]), "coming_of_age", year, {})

	# 3. Deaths. age >= death_age → dead. Logs the event, sets alive=0,
	#    spawns "widowed" events for spouses, and triggers succession on any
	#    holdings the deceased held.
	db.query("""
		SELECT id FROM characters
		WHERE alive = 1 AND age >= death_age;""")
	var dying: Array = []
	for row in db.query_result:
		dying.append(int(row["id"]))
	for cid in dying:
		_die(cid, year)

	# 4. Marriage matching — hierarchy-aware. See _try_match_marriages.
	_try_match_marriages(year)

	# 5. Spawn-spouse fallback: unwed barony lords aged 30+ get a partner
	#    spawned in from the regional name pool (no permission needed).
	_spawn_partner_fallback(year)

	# 6. Yearly fertility roll for married couples — newborns get added.
	_spawn_children(year)


# Tier rank: lower = higher in the hierarchy. Used to score marriage
# candidates (we prefer pairings near the same tier).
const TIER_RANK := {"country": 0, "duchy": 1, "county": 2, "barony": 3}
const NO_HOLDING_TIER := 4


# Record a death: log the event, flip alive to 0, mark widowed spouses,
# transfer holdings to heirs (or escheat). See _process_succession.
func _die(cid: int, year: int) -> void:
	_log_lifecycle(cid, "death", year, {})
	db.query_with_bindings("UPDATE characters SET alive = 0 WHERE id = ?;", [cid])
	db.query_with_bindings("""
		SELECT related_id FROM relationships
		WHERE character_id = ? AND kind = 'spouse';""", [cid])
	for row in db.query_result:
		_log_lifecycle(int(row["related_id"]), "widowed", year, {"of_id": cid})
	# Succession on every holding the deceased had.
	db.query_with_bindings("""
		SELECT region_type, region_id FROM holdings WHERE holder_character_id = ?;""",
		[cid])
	var holdings: Array = []
	for row in db.query_result:
		holdings.append({"region_type": str(row["region_type"]), "region_id": str(row["region_id"])})
	for h in holdings:
		_process_succession(cid, h.region_type, h.region_id, year)


# ── MARRIAGE ─────────────────────────────────────────────────────────────────
# Hierarchy-aware matchmaker. For every eligible bachelor, we search the
# bachelorettes in this preference order:
#   1. SAME tier as the groom's family (peers)
#   2. ONE tier UP (marrying into a higher house, requires liege permission)
#   3. ONE tier DOWN (marrying into a lesser house)
# Best candidate within the preferred band is scored on age proximity and a
# small random jitter, then the marriage is evaluated against a heuristic
# that approximates the liege's approval.
const MARRIAGES_PER_YEAR := 60
const AGE_GAP_MAX := 12
func _try_match_marriages(year: int) -> void:
	var bachelors: Array = _eligible_singles_ranked("male", 18, 999)
	var bachelorettes: Array = _eligible_singles_ranked("female", 16, 35)
	if bachelors.is_empty() or bachelorettes.is_empty():
		return
	var used: Dictionary = {}     # character_id → true once taken this tick
	var paired: int = 0
	for groom in bachelors:
		if paired >= MARRIAGES_PER_YEAR:
			return
		if used.has(int(groom.id)):
			continue
		var bride = _find_best_match(groom, bachelorettes, used)
		if bride == null:
			continue
		var verdict: Dictionary = _evaluate_marriage(groom, bride)
		if verdict.accept:
			_consummate_marriage(int(groom.id), int(bride.id), year, str(verdict.note))
			used[int(groom.id)] = true
			used[int(bride.id)] = true
			paired += 1
		else:
			# Mark the bride as used this tick anyway so other grooms don't
			# all converge on her in the same year.
			used[int(bride.id)] = true


# Pick the best bride for a groom, walking the hierarchy preference bands.
# Returns the bride row (with family_tier annotation) or null if no match.
func _find_best_match(groom: Dictionary, brides: Array, used: Dictionary):
	var groom_tier: int = int(groom.get("family_tier", NO_HOLDING_TIER))
	# Preference bands: same tier first, then up one, then down one, then any.
	var bands: Array = [0, -1, 1, -2, 2, -3, 3]
	for tier_delta in bands:
		var target_tier: int = groom_tier + tier_delta
		var best = null
		var best_score: float = -INF
		for bride in brides:
			if used.has(int(bride.id)):
				continue
			if int(bride.family_id) == int(groom.family_id):
				continue
			if abs(int(bride.age) - int(groom.age)) > AGE_GAP_MAX:
				continue
			if int(bride.family_tier) != target_tier:
				continue
			# Score: lower age gap = better, plus a small jitter.
			var age_gap: int = absi(int(bride.age) - int(groom.age))
			var score: float = (AGE_GAP_MAX - age_gap) + GaussianSystem.sample(0.0, 1.5)
			if score > best_score:
				best_score = score
				best = bride
		if best != null:
			return best
	return null


# Liege-approval heuristic. Score = base 50 + tier compatibility ± Gaussian.
# Tier deltas:
#   |Δtier| = 0  → +20 (best)
#   |Δtier| = 1  → +10
#   |Δtier| = 2  →   0
#   |Δtier| >= 3 → -10 (mismatched pairing rarely approved)
# Accept threshold: score > 50.
func _evaluate_marriage(groom: Dictionary, bride: Dictionary) -> Dictionary:
	var g_tier: int = int(groom.get("family_tier", NO_HOLDING_TIER))
	var b_tier: int = int(bride.get("family_tier", NO_HOLDING_TIER))
	var delta: int = absi(g_tier - b_tier)
	var tier_bonus: int = 20
	if delta == 1: tier_bonus = 10
	elif delta == 2: tier_bonus = 0
	elif delta >= 3: tier_bonus = -10
	var jitter: float = GaussianSystem.sample(0.0, 10.0)
	var score: float = 50.0 + float(tier_bonus) + jitter
	var note: String = "Δtier=%d, jitter=%.1f, score=%.1f" % [delta, jitter, score]
	return {"accept": score > 50.0, "note": note}


# Eligible singles + family_tier annotation. Pulls every alive unwed
# character of the given gender within an age window and computes their
# family's tier (max tier of any holding any family member currently holds).
func _eligible_singles_ranked(gender: String, min_age: int, max_age: int) -> Array:
	db.query_with_bindings("""
		SELECT c.id, c.given_name, c.family_id, c.age
		FROM characters c
		WHERE c.alive = 1 AND c.gender = ? AND c.age >= ? AND c.age <= ?
		  AND NOT EXISTS (
			SELECT 1 FROM relationships r
			WHERE r.character_id = c.id AND r.kind = 'spouse'
		  )
		ORDER BY c.age ASC, c.id ASC;""",
		[gender, min_age, max_age]
	)
	var rows: Array = []
	for row in db.query_result:
		rows.append(row.duplicate())
	# Annotate with family_tier (lowest TIER_RANK across the family's holdings).
	var family_tiers: Dictionary = _compute_family_tiers()
	for r in rows:
		r["family_tier"] = int(family_tiers.get(int(r.family_id), NO_HOLDING_TIER))
	return rows


# Map family_id → tier (lower = higher rank) by scanning every holding.
func _compute_family_tiers() -> Dictionary:
	db.query("""
		SELECT h.holder_family_id AS fid, h.region_type AS rt FROM holdings h;""")
	var out: Dictionary = {}
	for row in db.query_result:
		var fid: int = int(row["fid"])
		var tier: int = int(TIER_RANK.get(str(row["rt"]), NO_HOLDING_TIER))
		if not out.has(fid) or tier < int(out[fid]):
			out[fid] = tier
	return out


# Actually perform the marriage: insert spouse edges + log events.
func _consummate_marriage(groom_id: int, bride_id: int, year: int, note: String = "") -> void:
	_link_pair(groom_id, bride_id, "spouse")
	var payload: Dictionary = {"spouse_id": bride_id}
	if note != "":
		payload["note"] = note
	_log_lifecycle(groom_id, "marriage", year, payload)
	payload = {"spouse_id": groom_id}
	if note != "":
		payload["note"] = note
	_log_lifecycle(bride_id, "marriage", year, payload)


# Spawn a randomly-generated partner for unwed barony holders aged 30+.
# This is the "if no eligible match exists, you settle locally" fallback —
# only valid for the lowest tier (barons). Higher tiers stay unwed.
func _spawn_partner_fallback(year: int) -> void:
	if not DesignData.loaded:
		return
	db.query("""
		SELECT c.id, c.family_id, c.gender, c.age
		FROM characters c
		WHERE c.alive = 1 AND c.age >= 30
		  AND NOT EXISTS (
			SELECT 1 FROM relationships r
			WHERE r.character_id = c.id AND r.kind = 'spouse'
		  )
		  AND EXISTS (
			SELECT 1 FROM holdings h
			WHERE h.holder_character_id = c.id AND h.region_type = 'barony'
		  );""")
	var lonely: Array = []
	for row in db.query_result:
		lonely.append(row.duplicate())
	for row in lonely:
		var partner_gender: String = "female" if str(row.gender) == "male" else "male"
		# Pick a name pool: derive region letter from the holder's barony LAD.
		var region_letter: String = _region_letter_for_barony_holder(int(row.id))
		var pools: Dictionary = DesignData.name_pools
		var given_pool: Array = pools.get("female" if partner_gender == "female" else "male", {}).get(region_letter, [])
		if given_pool.is_empty():
			given_pool = pools.get("female" if partner_gender == "female" else "male", {}).get("E", [])
		var surname_pool: Array = pools.get("surnames", {}).get(region_letter, [])
		if surname_pool.is_empty():
			surname_pool = pools.get("surnames", {}).get("E", [])
		if given_pool.is_empty() or surname_pool.is_empty():
			continue
		var seed_str: String = "spawn:%d:%d" % [int(row.id), year]
		var given_name: String = given_pool[_hash_int(seed_str, 1) % given_pool.size()]
		var sn: String = surname_pool[_hash_int(seed_str, 2) % surname_pool.size()]
		# Partner age: ±5 of lord's age, clamped to marriageable window.
		var lord_age: int = int(row.age)
		var p_min: int = 18 if partner_gender == "male" else 16
		var p_max: int = 60 if partner_gender == "male" else 35
		var partner_age: int = clampi(lord_age + ((_hash_int(seed_str, 3) % 11) - 5), p_min, p_max)
		var fid: int = _ensure_family(sn, 35)
		var title: String = "Lord" if partner_gender == "male" else "Lady"
		var pid: int = _insert_character(given_name, fid, title, partner_age, partner_gender)
		# Order matters for `_consummate_marriage` — groom (male) first.
		if str(row.gender) == "male":
			_consummate_marriage(int(row.id), pid, year, "spawned-partner")
		else:
			_consummate_marriage(pid, int(row.id), year, "spawned-partner")


# Best-guess country letter (E/W/S) for a barony holder from their LAD13CD.
func _region_letter_for_barony_holder(cid: int) -> String:
	db.query_with_bindings("""
		SELECT region_id FROM holdings
		WHERE holder_character_id = ? AND region_type = 'barony' LIMIT 1;""",
		[cid]
	)
	if db.query_result.is_empty():
		return "E"
	var lad: String = str(db.query_result[0]["region_id"])
	if lad.length() == 0:
		return "E"
	return lad.substr(0, 1)


# ── CHILDREN ─────────────────────────────────────────────────────────────────
# Per-year fertility roll on every alive married couple. Mother age is the
# limiting factor (women bear children until ~45 historically). 22% baseline
# chance per year, lifted slightly for younger couples.
const CHILD_BASE_CHANCE := 0.22
const CHILD_MOTHER_AGE_MAX := 45
const CHILD_FATHER_AGE_MAX := 70
func _spawn_children(year: int) -> void:
	if not DesignData.loaded:
		return
	# Pull each unique couple (spouse rel is bidirectional, so dedupe by id-order).
	db.query("""
		SELECT r.character_id AS a, r.related_id AS b
		FROM relationships r
		WHERE r.kind = 'spouse' AND r.character_id < r.related_id;""")
	var couples: Array = []
	for row in db.query_result:
		couples.append({"a": int(row["a"]), "b": int(row["b"])})
	for couple in couples:
		_maybe_birth(couple.a, couple.b, year)


func _maybe_birth(a_id: int, b_id: int, year: int) -> void:
	var a: Dictionary = character(a_id)
	var b: Dictionary = character(b_id)
	if a.is_empty() or b.is_empty():
		return
	if not bool(a.get("alive", false)) or not bool(b.get("alive", false)):
		return
	# Identify mother/father by gender.
	var mother: Dictionary
	var father: Dictionary
	if str(a.get("gender", "")) == "female":
		mother = a; father = b
	else:
		mother = b; father = a
	if str(mother.get("gender", "")) != "female" or str(father.get("gender", "")) != "male":
		return  # only opposite-sex pairings produce children in this model
	var m_age: int = int(mother.get("age", 0))
	var f_age: int = int(father.get("age", 0))
	if m_age > CHILD_MOTHER_AGE_MAX or m_age < 16:
		return
	if f_age > CHILD_FATHER_AGE_MAX or f_age < 18:
		return
	# Per-year roll. Slight age penalty after 35.
	var chance: float = CHILD_BASE_CHANCE
	if m_age > 35:
		chance *= 0.6
	if randf() > chance:
		return
	_spawn_child(int(father.character_id), int(mother.character_id), year)


# Insert a newborn: child takes father's family (patrilineal), random gender,
# age 0. Linked as child of both parents.
func _spawn_child(father_id: int, mother_id: int, year: int) -> void:
	var father: Dictionary = character(father_id)
	if father.is_empty():
		return
	var father_family_id: int = int(father.get("family_id", 0))
	var father_surname: String = str(father.get("surname", "Unknown"))
	var region_letter: String = _region_letter_for_surname(father_surname)
	var pools: Dictionary = DesignData.name_pools
	var gender: String = "male" if (randi() % 2 == 0) else "female"
	var pool: Array = pools.get("male" if gender == "male" else "female", {}).get(region_letter, [])
	if pool.is_empty():
		pool = pools.get("male" if gender == "male" else "female", {}).get("E", [])
	if pool.is_empty():
		return
	var given_name: String = pool[randi() % pool.size()]
	var cid: int = _insert_character(given_name, father_family_id,
			"Lord" if gender == "male" else "Lady", 0, gender)
	_link_pair(father_id, cid, "child")
	_link_pair(mother_id, cid, "child")
	# Override the inferred birth year so it matches the simulation year.
	db.query_with_bindings("""
		UPDATE lifecycle_events SET year = ?
		WHERE character_id = ? AND kind = 'birth';""", [year, cid])


# Best-guess country letter from a surname; mirrors _region_for_surname but
# returns "E"/"W"/"S" letters directly.
func _region_letter_for_surname(surname: String) -> String:
	return _region_for_surname(surname)


# ── INHERITANCE ──────────────────────────────────────────────────────────────
# When a holder dies, walk the family tree for an heir. Priority order:
#   1. Eldest living son (same family, male child)
#   2. Eldest younger son
#   3. Eldest living brother (male sibling, same family)
#   4. Escheat to the holding's liege (parent_region's holder)
#
# Liege block: when a non-trivial inheritance happens (heir would relocate
# from another region of equal/higher tier), the new liege has a Gaussian
# chance to block — failed blocks escheat instead. For Phase B we keep this
# light; the framework is here for future depth.
func _process_succession(deceased_id: int, region_type: String, region_id: String, year: int) -> void:
	var heir: Dictionary = _find_heir(deceased_id)
	if heir.is_empty():
		_escheat(region_type, region_id, year)
		return
	var heir_id: int = int(heir.get("character_id", heir.get("id", 0)))
	if heir_id <= 0:
		_escheat(region_type, region_id, year)
		return
	# Liege block check. We compare the heir's CURRENT primary tier to the
	# inherited region's tier — climbing UP to a higher tier triggers a roll.
	if _liege_blocks_inheritance(heir_id, region_type, region_id):
		_log_lifecycle(heir_id, "inheritance_blocked", year, {
			"region_type": region_type, "region_id": region_id,
			"from_id": deceased_id,
		})
		_escheat(region_type, region_id, year)
		return
	# Heir relocates: they ABANDON their existing holdings (which escheat
	# to their previous lieges) and take the inherited one. This is the
	# "leave their existing post and physical location" the user described.
	var prev_holdings: Array = holdings_of(heir_id)
	for prev in prev_holdings:
		_escheat(str(prev.region_type), str(prev.region_id), year)
	# Transfer the inherited holding.
	var heir_family_id: int = int(character(heir_id).get("family_id", 0))
	_set_holding(region_type, region_id, heir_id, heir_family_id)
	_log_lifecycle(heir_id, "inherited", year, {
		"region_type": region_type, "region_id": region_id,
		"from_id": deceased_id,
	})


# Eldest living male child of deceased, then eldest male sibling, then {}.
# Returns {character_id, age, family_id} or {} for none-found.
func _find_heir(deceased_id: int) -> Dictionary:
	# 1. Sons of deceased — alive, male, oldest first.
	db.query_with_bindings("""
		SELECT c.id AS character_id, c.age, c.family_id
		FROM relationships r
		JOIN characters c ON c.id = r.related_id
		WHERE r.character_id = ? AND r.kind = 'child' AND c.alive = 1 AND c.gender = 'male'
		ORDER BY c.age DESC LIMIT 1;""", [deceased_id])
	if not db.query_result.is_empty():
		return db.query_result[0].duplicate()
	# 2. Brothers — male sibling, alive, oldest first.
	db.query_with_bindings("""
		SELECT c.id AS character_id, c.age, c.family_id
		FROM relationships r
		JOIN characters c ON c.id = r.related_id
		WHERE r.character_id = ? AND r.kind = 'sibling' AND c.alive = 1 AND c.gender = 'male'
		ORDER BY c.age DESC LIMIT 1;""", [deceased_id])
	if not db.query_result.is_empty():
		return db.query_result[0].duplicate()
	return {}


# Liege blocks the inheritance with a chance proportional to how big a
# promotion the heir is getting. Climbing two tiers up has a real chance
# of being blocked; lateral / down moves never blocked. Returns true to
# block (escheat instead of transfer).
func _liege_blocks_inheritance(heir_id: int, inherited_type: String, _inherited_id: String) -> bool:
	var heir_prev: Array = holdings_of(heir_id)
	if heir_prev.is_empty():
		return false   # no prior post, no political objection
	var inherited_tier: int = int(TIER_RANK.get(inherited_type, NO_HOLDING_TIER))
	var heir_top_tier: int = NO_HOLDING_TIER
	for h in heir_prev:
		var t: int = int(TIER_RANK.get(str(h.region_type), NO_HOLDING_TIER))
		if t < heir_top_tier:
			heir_top_tier = t
	# Climbing UP (smaller tier number): roll a block chance ~ 15% per step.
	if inherited_tier >= heir_top_tier:
		return false
	var steps: int = heir_top_tier - inherited_tier
	var block_chance: float = 0.15 * float(steps)
	return randf() < block_chance


# Transfer a holding to the holding's parent (liege's) holder. If no parent
# exists (country tier), the holding becomes unowned and is logged as such.
func _escheat(region_type: String, region_id: String, year: int) -> void:
	var parent: Dictionary = parent_region(region_type, region_id)
	if parent.is_empty():
		# Top-tier (country) escheat: leave unowned for now. Log the event.
		db.query_with_bindings(
			"DELETE FROM holdings WHERE region_type = ? AND region_id = ?;",
			[region_type, region_id]
		)
		return
	var liege: Dictionary = holder_of(parent.region_type, parent.region_id)
	if liege.is_empty():
		db.query_with_bindings(
			"DELETE FROM holdings WHERE region_type = ? AND region_id = ?;",
			[region_type, region_id]
		)
		return
	var liege_id: int = int(liege.get("character_id", 0))
	var liege_family_id: int = int(liege.get("family_id", 0))
	_set_holding(region_type, region_id, liege_id, liege_family_id)
	_log_lifecycle(liege_id, "escheated", year, {
		"region_type": region_type, "region_id": region_id,
	})


func _log_lifecycle(character_id: int, kind: String, year: int, payload: Dictionary) -> void:
	db.query_with_bindings("""
		INSERT INTO lifecycle_events(character_id, kind, year, payload_json)
		VALUES(?,?,?,?);""",
		[character_id, kind, year, JSON.stringify(payload)]
	)


# Read all lifecycle events for one character, oldest first.
func lifecycle_events_of(character_id: int) -> Array:
	db.query_with_bindings("""
		SELECT kind, year, payload_json FROM lifecycle_events
		WHERE character_id = ?
		ORDER BY year ASC, id ASC;""",
		[character_id]
	)
	var out: Array = []
	for row in db.query_result:
		out.append({
			"kind": str(row["kind"]),
			"year": int(row["year"]),
			"payload_json": str(row["payload_json"]),
		})
	return out


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


# Aggregate faction-level economy summary for the TopBar chips. Sums income
# across every county the faction owns, averages their fertility, and counts
# devastated counties (no-yield this turn). Treasury comes straight from
# factions.treasury but is exposed here so the TopBar only needs one call.
#
# Args:
#   faction_id (String): lowercase id ("england" / "wales" / "scotland").
# Returns:
#   Dictionary: {treasury, total_income, mean_fertility, county_count,
#                devastated_count}.
func faction_economy_summary(faction_id: String) -> Dictionary:
	var out: Dictionary = {
		"treasury": 0, "total_income": 0,
		"mean_fertility": 0.0, "county_count": 0,
		"devastated_count": 0,
	}
	if db == null:
		return out
	var f: Dictionary = faction(faction_id)
	out.treasury = int(f.get("treasury", 0))
	db.query_with_bindings(
		"SELECT county_id, fertility FROM counties_state WHERE owner_faction_id = ?;",
		[faction_id]
	)
	var total_inc: int = 0
	var fert_sum: float = 0.0
	var n: int = 0
	for row in db.query_result:
		var cn: String = str(row["county_id"])
		var co: Dictionary = MapData.get_county(cn)
		total_inc += int(co.get("income", 0))
		fert_sum += float(row["fertility"])
		n += 1
	out.total_income = total_inc
	out.county_count = n
	if n > 0:
		out.mean_fertility = fert_sum / float(n)
	return out


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


# ── HIERARCHY ─────────────────────────────────────────────────────────────────
# Geographic / political tier walking. country > duchy > county > barony.
# The parent of a barony is the county it sits in; of a county, its duchy;
# of a duchy, its country. Sources are MapData (county.duchy, county.baronies,
# COUNTRY_BY_DUCHY).

# Region one tier above this region. Returns {region_type, region_id} or {}.
func parent_region(region_type: String, region_id: String) -> Dictionary:
	match region_type:
		"barony":
			# Walk MapData.counties — each county has a baronies array.
			for cn in MapData.counties:
				for b in MapData.counties[cn].get("baronies", []):
					if str(b.get("id", "")) == region_id:
						return {"region_type": "county", "region_id": cn}
			return {}
		"county":
			var did: String = str(MapData.counties.get(region_id, {}).get("duchy", ""))
			if did == "":
				return {}
			return {"region_type": "duchy", "region_id": did}
		"duchy":
			var country: String = str(MapData.COUNTRY_BY_DUCHY.get(region_id, ""))
			if country == "":
				return {}
			return {"region_type": "country", "region_id": country.to_lower()}
	return {}


# Regions one tier BELOW this region. country→duchies, duchy→counties, etc.
func child_regions(region_type: String, region_id: String) -> Array:
	var out: Array = []
	match region_type:
		"country":
			for did in MapData.duchies:
				if str(MapData.COUNTRY_BY_DUCHY.get(did, "")).to_lower() == region_id.to_lower():
					out.append({"region_type": "duchy", "region_id": did})
		"duchy":
			for cn in MapData.counties:
				if str(MapData.counties[cn].get("duchy", "")) == region_id:
					out.append({"region_type": "county", "region_id": cn})
		"county":
			for b in MapData.counties.get(region_id, {}).get("baronies", []):
				out.append({"region_type": "barony", "region_id": str(b.get("id", ""))})
	return out


# The character holding the region one tier above this character's PRIMARY
# holding (first in the country>duchy>county>barony ordering). For a baron,
# that's the earl of his county; for an earl, the duke of his duchy; etc.
#
# Args:
#   character_id (int)
# Returns:
#   Dictionary: holder row + region context, or {} if none.
func liege_of(character_id: int) -> Dictionary:
	var holds: Array = holdings_of(character_id)
	if holds.is_empty():
		return {}
	var primary: Dictionary = holds[0]
	var parent: Dictionary = parent_region(primary.region_type, primary.region_id)
	if parent.is_empty():
		return {}
	var h: Dictionary = holder_of(parent.region_type, parent.region_id)
	if h.is_empty():
		return {}
	h["region_type"] = parent.region_type
	h["region_id"] = parent.region_id
	return h


# Characters holding the regions one tier BELOW each region this character
# holds. Returns an array of holder rows annotated with the region they hold.
func vassals_of(character_id: int) -> Array:
	var out: Array = []
	for h in holdings_of(character_id):
		for child in child_regions(h.region_type, h.region_id):
			var holder: Dictionary = holder_of(child.region_type, child.region_id)
			if holder.is_empty():
				continue
			holder["region_type"] = child.region_type
			holder["region_id"] = child.region_id
			out.append(holder)
	return out


# ── OPINIONS ──────────────────────────────────────────────────────────────────

# Read political opinion of A toward B. Missing rows = 0 (neutral).
func opinion_of(character_id: int, target_id: int) -> int:
	if character_id <= 0 or target_id <= 0:
		return 0
	db.query_with_bindings(
		"SELECT opinion FROM character_opinions WHERE character_id = ? AND target_id = ?;",
		[character_id, target_id]
	)
	if db.query_result.is_empty():
		return 0
	return int(db.query_result[0]["opinion"])


# Add `delta` to A's opinion of B. Creates the row if it doesn't exist.
# Returns the new value. Emits state_changed.
func adjust_opinion(character_id: int, target_id: int, delta: int) -> int:
	if character_id == target_id:
		return 0
	var current: int = opinion_of(character_id, target_id)
	var new_val: int = clampi(current + delta, -100, 100)
	db.query_with_bindings("""
		INSERT INTO character_opinions(character_id, target_id, opinion, last_changed_turn)
		VALUES(?,?,?,?)
		ON CONFLICT(character_id, target_id) DO UPDATE
			SET opinion = excluded.opinion, last_changed_turn = excluded.last_changed_turn;""",
		[character_id, target_id, new_val, current_turn()]
	)
	state_changed.emit()
	return new_val


# ── ACTIONS ───────────────────────────────────────────────────────────────────
# Catalogue of action types. Each entry describes who can initiate it, who the
# target is, and whether it resolves immediately or sits pending for the
# target's reply. Effects on opinion are applied at resolution time.
#
# `direction` semantics:
#   "up"        — initiator is a vassal acting on their liege
#   "down"      — initiator is a liege acting on a vassal
#   "peer"      — initiator and target are roughly co-equal (same tier)
#   "self"      — only the initiator is involved (e.g. take a vow)
#
# `resolution`:
#   "immediate" — applies effects right away, no pending row
#   "reply"     — creates a pending action; target accepts/declines later
# Each action specifies a `prestige_cost` (deducted from initiator's family
# prestige on submit; submit is rejected if insufficient) and, optionally,
# a `requires_office` key — only characters currently holding that office
# anywhere can invoke the action. The UI tags such actions with a bordered
# style and a "(privilege of <office>)" tooltip.
const ACTION_CATALOG: Dictionary = {
	# ── Base actions (no office needed) ──
	"request_marriage": {
		"label": "Request marriage alliance",
		"direction": "up", "resolution": "reply",
		"prestige_cost": 10,
		"description": "Ask your liege to approve a marriage between your families.",
		"on_accept_opinion": +15, "on_decline_opinion": -10,
	},
	"grant_aid": {
		"label": "Grant aid",
		"direction": "down", "resolution": "immediate",
		"prestige_cost": 15,
		"description": "Send treasury support to a vassal in need.",
		"on_accept_opinion": +20,
	},
	"appoint_office": {
		"label": "Appoint to office",
		"direction": "down", "resolution": "immediate",
		"prestige_cost": 5,
		"description": "Place this vassal in one of your court offices.",
		"on_accept_opinion": +10,
	},
	"swear_fealty": {
		"label": "Swear fealty",
		"direction": "up", "resolution": "immediate",
		"prestige_cost": 5,
		"description": "Reaffirm your loyalty to your liege.",
		"on_accept_opinion": +5,
	},
	# ── Office-granted actions ──
	# Each requires the actor to currently hold the named office at any tier.
	"raise_levy": {
		"label": "Raise levy",
		"direction": "self", "resolution": "immediate",
		"prestige_cost": 20,
		"requires_office": "marshal",
		"description": "Mobilise troops from your demesne for a campaign.",
	},
	"declare_war": {
		"label": "Declare war",
		"direction": "peer", "resolution": "immediate",
		"prestige_cost": 50,
		"requires_office": "marshal",
		"description": "Formally declare war on a peer realm.",
		"on_accept_opinion": -50,
	},
	"levy_special_tax": {
		"label": "Levy special tax",
		"direction": "down", "resolution": "immediate",
		"prestige_cost": 10,
		"requires_office": "treasurer",
		"description": "Extract additional taxes from a vassal.",
		"on_accept_opinion": -10,
	},
	"sponsor_works": {
		"label": "Sponsor public works",
		"direction": "down", "resolution": "immediate",
		"prestige_cost": 25,
		"requires_office": "treasurer",
		"description": "Bankroll roads, bridges, or marketplaces in a vassal's demesne.",
		"on_accept_opinion": +15,
	},
	"forge_alliance": {
		"label": "Forge alliance",
		"direction": "peer", "resolution": "reply",
		"prestige_cost": 25,
		"requires_office": "chancellor",
		"description": "Negotiate a mutual defence pact with another realm.",
		"on_accept_opinion": +20, "on_decline_opinion": -5,
	},
	"sue_for_peace": {
		"label": "Sue for peace",
		"direction": "peer", "resolution": "reply",
		"prestige_cost": 15,
		"requires_office": "chancellor",
		"description": "Offer terms to end an ongoing war.",
		"on_accept_opinion": +10,
	},
	"spy_on_court": {
		"label": "Spy on court",
		"direction": "peer", "resolution": "immediate",
		"prestige_cost": 15,
		"requires_office": "spymaster",
		"description": "Plant agents in another lord's court to read his correspondence.",
	},
	"bless_marriage": {
		"label": "Bless marriage",
		"direction": "down", "resolution": "immediate",
		"prestige_cost": 5,
		"requires_office": "chaplain",
		"description": "Bestow ecclesiastical blessing on a vassal's marriage.",
		"on_accept_opinion": +15,
	},
	"excommunicate": {
		"label": "Excommunicate",
		"direction": "down", "resolution": "immediate",
		"prestige_cost": 40,
		"requires_office": "chaplain",
		"description": "Remove a vassal from the protection of the Church.",
		"on_accept_opinion": -50,
	},
}


# Office key → human-readable label used in tooltips ("privilege of …").
# Each office key appears in EXACTLY ONE tier (no overlap across the
# hierarchy) so a "Marshal" never co-exists with a "Marshal" two tiers
# down — privileges are bound to a specific tier of court.
const OFFICE_LABELS: Dictionary = {
	# Country tier — Great Officers of the Realm.
	"marshal":     "Marshal",
	"chancellor":  "Chancellor",
	"spymaster":   "Spymaster",
	"chaplain":    "Chaplain",
	"treasurer":   "Treasurer",
	# Duchy tier — ducal household.
	"constable":   "Constable",
	"seneschal":   "Seneschal",
	"herald":      "Herald",
	"justiciar":   "Justiciar",
	# County tier — county officers.
	"sheriff":     "Sheriff",
	"coroner":     "Coroner",
	"bailiff":     "Bailiff",
	# Barony tier — manor officers.
	"castellan":   "Castellan",
	"reeve":       "Reeve",
	"forester":    "Forester",
}


# Per-tier office rosters. Every office key is tier-unique (no overlap), so
# the privileges granted by each office are naturally tier-specific.
const OFFICES_BY_TIER: Dictionary = {
	"country": ["marshal", "chancellor", "spymaster", "chaplain", "treasurer"],
	"duchy":   ["constable", "seneschal", "herald", "justiciar"],
	"county":  ["sheriff", "coroner", "bailiff"],
	"barony":  ["castellan", "reeve", "forester"],
}


# Look up the holder of a specific office slot at a region. Returns a holder
# row (character_id + given_name + surname + age + alive + ...) or {} when
# the slot is vacant.
func office_holder(region_type: String, region_id: String, office_key: String) -> Dictionary:
	db.query_with_bindings("""
		SELECT c.id AS character_id, c.given_name, c.title, c.age, c.gender, c.alive,
			   f.id AS family_id, f.surname, f.prestige
		FROM offices o
		JOIN characters c ON c.id = o.holder_character_id
		LEFT JOIN families f ON f.id = c.family_id
		WHERE o.region_type = ? AND o.region_id = ? AND o.office_key = ?
		LIMIT 1;""",
		[region_type, region_id, office_key]
	)
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()


# Which actions can `actor` take against `target`? Filters ACTION_CATALOG by
# the actor↔target hierarchical relationship. If `target_id` is 0 we return
# only "self" actions.
#
# Args:
#   actor_id (int): the initiator (typically the player or whichever character
#       the player is acting AS).
#   target_id (int): the target character (0 for none).
# Returns:
#   Array of dicts: [{key, label, description, direction, ...}]
# All actions THIS character qualifies for, regardless of target. Used by
# the character panel to show "Actions available to <name>" — the player
# can see at a glance which privileges the character carries (especially
# office-granted ones), without needing to also pick a target.
#
# Args:
#   character_id (int): the actor.
# Returns:
#   Array of action descriptors (catalog entry + "key" field). Office-gated
#   actions only appear when the character currently holds the required
#   office at any tier.
func actions_for(character_id: int) -> Array:
	var out: Array = []
	if character_id <= 0:
		return out
	var actor_offices: Dictionary = _office_keys_held_by(character_id)
	for key in ACTION_CATALOG.keys():
		var spec: Dictionary = ACTION_CATALOG[key]
		if "requires_office" in spec:
			if not actor_offices.has(str(spec.requires_office)):
				continue
		var entry: Dictionary = spec.duplicate()
		entry["key"] = key
		out.append(entry)
	return out


func available_actions(actor_id: int, target_id: int = 0) -> Array:
	var out: Array = []
	if actor_id <= 0:
		return out
	var relation: String = _hierarchical_relation(actor_id, target_id)
	var actor_offices: Dictionary = _office_keys_held_by(actor_id)
	for key in ACTION_CATALOG.keys():
		var spec: Dictionary = ACTION_CATALOG[key]
		if str(spec.direction) != relation:
			continue
		# Office gating: filter out actions the actor lacks the privilege for.
		if "requires_office" in spec:
			if not actor_offices.has(str(spec.requires_office)):
				continue
		var entry: Dictionary = spec.duplicate()
		entry["key"] = key
		out.append(entry)
	return out


# Lookup table {office_key: true} for offices this character currently holds.
# Returned as a Dict for O(1) membership check by available_actions.
func _office_keys_held_by(character_id: int) -> Dictionary:
	if character_id <= 0:
		return {}
	db.query_with_bindings("""
		SELECT DISTINCT office_key FROM offices
		WHERE holder_character_id = ?;""", [character_id])
	var out: Dictionary = {}
	for row in db.query_result:
		out[str(row["office_key"])] = true
	return out


# Walks the hierarchy to classify how `target` relates to `actor`:
#   self  — same character
#   up    — target is the actor's liege
#   down  — target is one of actor's vassals
#   peer  — same tier, no liege/vassal relationship
#   ""    — unrelated / unknown
func _hierarchical_relation(actor_id: int, target_id: int) -> String:
	if actor_id <= 0:
		return ""
	if target_id <= 0:
		return "self"
	if actor_id == target_id:
		return "self"
	var liege: Dictionary = liege_of(actor_id)
	if not liege.is_empty() and int(liege.get("character_id", 0)) == target_id:
		return "up"
	for v in vassals_of(actor_id):
		if int(v.get("character_id", 0)) == target_id:
			return "down"
	# Same-tier peer detection: do they hold regions at the same tier?
	var a_holds: Array = holdings_of(actor_id)
	var t_holds: Array = holdings_of(target_id)
	if not a_holds.is_empty() and not t_holds.is_empty():
		if str(a_holds[0].region_type) == str(t_holds[0].region_type):
			return "peer"
	return ""


# Submit an action. Resolves immediately for `immediate` actions, otherwise
# creates a pending row for the target to resolve later.
#
# Args:
#   action_type (String): key from ACTION_CATALOG.
#   actor_id (int)
#   target_id (int): 0 for self-actions.
#   payload (Dictionary): action-specific extras (e.g. for marriage:
#       {"groom_id": int, "bride_id": int}).
# Returns:
#   Dictionary: {action_id, status, resolution_text}
func submit_action(action_type: String, actor_id: int, target_id: int = 0,
		payload: Dictionary = {}) -> Dictionary:
	if not ACTION_CATALOG.has(action_type):
		return {"status": "invalid", "resolution_text": "Unknown action " + action_type}
	var spec: Dictionary = ACTION_CATALOG[action_type]
	# Prestige gate. Family prestige is the per-character budget. If the
	# actor's family lacks enough prestige we reject the action before any
	# row is written. Cost is deducted immediately on submit, NOT refunded
	# on decline (the political effort of asking already spent the capital).
	var cost: int = int(spec.get("prestige_cost", 0))
	var actor_row: Dictionary = character(actor_id)
	if actor_row.is_empty():
		return {"status": "invalid", "resolution_text": "Unknown actor"}
	var family_id: int = int(actor_row.get("family_id", 0))
	var family_prestige: int = int(actor_row.get("prestige", 0))
	if family_prestige < cost:
		return {
			"status": "rejected",
			"resolution_text": "Insufficient prestige: %d/%d required." % [family_prestige, cost],
		}
	if cost > 0 and family_id > 0:
		db.query_with_bindings(
			"UPDATE families SET prestige = prestige - ? WHERE id = ?;",
			[cost, family_id]
		)
	var payload_str: String = JSON.stringify(payload)
	# SQLite addon needs an explicit `null` Variant for NULL columns; mixing
	# int and null in a ternary trips the GDScript type checker, so branch.
	var target_bind: Variant = null
	if target_id > 0:
		target_bind = target_id
	db.query_with_bindings("""
		INSERT INTO actions(action_type, initiator_id, target_id, payload_json, status, created_turn)
		VALUES(?,?,?,?,?,?);""",
		[action_type, actor_id, target_bind, payload_str, "pending", current_turn()]
	)
	var action_id: int = db.get_last_insert_rowid()
	if str(spec.resolution) == "immediate":
		return resolve_action(action_id, true)
	state_changed.emit()
	return {"action_id": action_id, "status": "pending",
			"resolution_text": "Sent to %s for reply." % _short_name(target_id)}


# Resolve a pending action. Applies opinion deltas, dispatches a per-type
# side-effect (e.g. appoint_office writes to the offices table; grant_aid
# moves gold between faction treasuries), and records resolution_text.
func resolve_action(action_id: int, accept: bool, custom_text: String = "") -> Dictionary:
	db.query_with_bindings("SELECT * FROM actions WHERE id = ?;", [action_id])
	if db.query_result.is_empty():
		return {"status": "invalid", "resolution_text": "Action not found"}
	var row: Dictionary = db.query_result[0].duplicate()
	if str(row.status) != "pending":
		return {"status": str(row.status),
				"resolution_text": "Already resolved"}
	var spec: Dictionary = ACTION_CATALOG.get(str(row.action_type), {})
	var actor: int = int(row.initiator_id)
	var target: int = int(row.target_id) if row.target_id != null else 0
	var new_status: String = "accepted" if accept else "declined"
	var op_delta: int = int(spec.get("on_accept_opinion", 0)) if accept else int(spec.get("on_decline_opinion", 0))
	# Opinion changes flow in BOTH directions: target's opinion of actor and
	# actor's opinion of target. Accept boosts both; decline cools both.
	if target > 0 and op_delta != 0:
		adjust_opinion(actor, target, op_delta)
		adjust_opinion(target, actor, op_delta)
	# Parse the payload (stored as JSON in the actions row) so the
	# side-effect dispatcher gets a real Dictionary.
	var payload: Dictionary = {}
	if row.has("payload_json") and row.payload_json != null:
		var raw: String = str(row.payload_json)
		if raw != "":
			var parsed = JSON.parse_string(raw)
			if parsed is Dictionary:
				payload = parsed
	# Side-effect dispatch only runs on ACCEPT. Decline collapses to opinion-
	# only. The helper returns a human-readable description of what it did
	# (or didn't) so the inbox/history shows something more useful than the
	# bare action key.
	var effect_text: String = ""
	if accept:
		effect_text = _apply_action_side_effects(str(row.action_type), actor, target, payload)
	var text: String = custom_text
	if text.is_empty():
		var verb: String = "accepted" if accept else "declined"
		text = "%s %s by %s" % [str(row.action_type), verb, _short_name(target)]
		if effect_text != "":
			text += " — " + effect_text
	db.query_with_bindings("""
		UPDATE actions SET status = ?, resolved_turn = ?, resolution_text = ?
		WHERE id = ?;""",
		[new_status, current_turn(), text, action_id]
	)
	state_changed.emit()
	return {"action_id": action_id, "status": new_status, "resolution_text": text}


# Per-action mechanical side-effects. Called from resolve_action only on
# ACCEPT. Each branch either applies its effect and returns a short summary
# string, or returns "" when the action carries no mechanical consequence
# beyond the opinion/prestige shifts already handled by submit/resolve.
#
# Args:
#   action_type (String): catalog key (e.g. "appoint_office", "grant_aid").
#   actor_id (int): initiator's character_id.
#   target_id (int): recipient's character_id (0 for self-actions).
#   payload (Dictionary): action-specific parameters carried on the actions
#       row (e.g. {office_key, region_type, region_id} for appoint_office).
# Returns:
#   String: human-readable summary of what happened, or "" if nothing.
func _apply_action_side_effects(action_type: String, actor_id: int,
		target_id: int, payload: Dictionary) -> String:
	match action_type:
		"appoint_office":
			# Liege grants the target an office. Payload MUST carry the office
			# slot keys — without them we'd have to guess which slot, which is
			# exactly the "what does this even do" problem the player ran into.
			var office_key: String = str(payload.get("office_key", ""))
			var region_type: String = str(payload.get("region_type", ""))
			var region_id: String = str(payload.get("region_id", ""))
			if office_key == "" or region_type == "" or region_id == "" or target_id <= 0:
				return "appointment skipped (no slot specified — use Court/Region panel)"
			# Eligibility: the candidate's family tier must reach the office's tier.
			var eligible: Array = eligible_office_candidates(region_type, region_id)
			var ok: bool = false
			for c in eligible:
				if int(c.get("character_id", 0)) == target_id:
					ok = true
					break
			if not ok:
				return "appointment refused (candidate ineligible for %s)" % office_key
			appoint_to_office(region_type, region_id, office_key, target_id)
			return "appointed %s of %s" % [str(OFFICE_LABELS.get(office_key, office_key)),
					str(region_id).capitalize()]
		"grant_aid":
			# Liege transfers gold from their faction treasury to the target's
			# faction treasury. Same-faction transfers are a paper move, so we
			# bump target's family prestige instead (the political weight of
			# the gift, since the money is from the same pool).
			var amount: int = int(payload.get("amount", 100))
			var actor_faction: String = _faction_of_character(actor_id)
			var target_faction: String = _faction_of_character(target_id)
			if actor_faction == "" or target_faction == "":
				return ""
			if actor_faction != target_faction:
				adjust_treasury(actor_faction, -amount)
				adjust_treasury(target_faction, amount)
				return "%d £ transferred to %s" % [amount, target_faction.capitalize()]
			# Same realm — convert the gesture into prestige for the target's house.
			_bump_family_prestige_of(target_id, 5)
			return "stipend of %d £ recorded (%s prestige +5)" % [amount, target_faction.capitalize()]
		"levy_special_tax":
			# Inverse of grant_aid: extract gold from a vassal's region into the
			# actor's faction. Reduces the target family's prestige (resentment).
			var amount2: int = int(payload.get("amount", 50))
			var actor_faction2: String = _faction_of_character(actor_id)
			if actor_faction2 != "":
				adjust_treasury(actor_faction2, amount2)
			_bump_family_prestige_of(target_id, -5)
			return "levy of %d £ collected" % amount2
		"sponsor_works":
			# Lord pays out of pocket to enrich a vassal's seat. For now the
			# treasury debit + prestige nudge stands in for a future region-
			# income buff (handled when the retinue/upkeep economy lands).
			var cost: int = int(payload.get("amount", 200))
			var af: String = _faction_of_character(actor_id)
			if af != "":
				adjust_treasury(af, -cost)
			_bump_family_prestige_of(target_id, 8)
			return "%d £ spent on public works" % cost
		"excommunicate":
			# Heavy prestige hit on the target's family, on top of the opinion
			# collapse already in the catalog.
			_bump_family_prestige_of(target_id, -25)
			return "target's house loses 25 prestige"
		"bless_marriage":
			_bump_family_prestige_of(target_id, 5)
			return "marriage blessed (+5 prestige to %s's house)" % _short_name(target_id)
		"swear_fealty":
			_bump_family_prestige_of(actor_id, 3)
			return "fealty sworn (+3 prestige to %s's house)" % _short_name(actor_id)
		"request_marriage", "forge_alliance", "sue_for_peace", "declare_war", \
		"spy_on_court", "raise_levy":
			# These need systems that don't exist yet (marriage UI payload,
			# alliances table, war state, knowledge graph, troops). The
			# opinion / prestige flow that already ran is the only effect for
			# now; surface that so the player isn't left wondering.
			return "no mechanical effect yet (system pending)"
	return ""


# Faction id (lowercase country) the character's primary holding belongs to.
# Falls back to the family's country if the character has no holdings of
# their own — covers landless courtiers and unwed heirs.
#
# Args:
#   character_id (int)
# Returns:
#   String: lowercase faction id ("england" / "wales" / "scotland"), or "".
func _faction_of_character(character_id: int) -> String:
	if character_id <= 0:
		return ""
	var holds: Array = holdings_of(character_id)
	if not holds.is_empty():
		var primary: Dictionary = holds[0]
		var rt: String = str(primary.region_type)
		var rid: String = str(primary.region_id)
		# Walk up to the country tier.
		while rt != "country":
			var parent: Dictionary = parent_region(rt, rid)
			if parent.is_empty():
				break
			rt = str(parent.region_type)
			rid = str(parent.region_id)
		if rt == "country":
			return rid.to_lower()
	# Fallback: read the character's family country if we stored one.
	var ch: Dictionary = character(character_id)
	return str(ch.get("country", "")).to_lower()


# Move the named character's FAMILY prestige by `delta`. Used by action
# side-effects that should reverberate beyond the actor (e.g. excommunicate
# damages the whole house, not just the individual).
func _bump_family_prestige_of(character_id: int, delta: int) -> void:
	if character_id <= 0 or delta == 0:
		return
	var ch: Dictionary = character(character_id)
	var fid: int = int(ch.get("family_id", 0))
	if fid <= 0:
		return
	db.query_with_bindings(
		"UPDATE families SET prestige = prestige + ? WHERE id = ?;",
		[delta, fid]
	)


# Actions awaiting `character_id`'s reply (i.e. they're the target of a
# pending action). Used to drive the "inbox" on the character sheet.
func pending_actions_for(character_id: int) -> Array:
	db.query_with_bindings("""
		SELECT a.*, c.given_name AS initiator_given, f.surname AS initiator_surname
		FROM actions a
		JOIN characters c ON c.id = a.initiator_id
		LEFT JOIN families f ON f.id = c.family_id
		WHERE a.target_id = ? AND a.status = 'pending'
		ORDER BY a.created_turn DESC;""",
		[character_id]
	)
	var out: Array = []
	for row in db.query_result:
		out.append(row.duplicate())
	return out


# Recent actions initiated by `character_id`. Used to show the player what
# they've recently done (and whether responses have come back).
func actions_by(character_id: int, limit: int = 10) -> Array:
	db.query_with_bindings("""
		SELECT * FROM actions
		WHERE initiator_id = ?
		ORDER BY created_turn DESC, id DESC
		LIMIT ?;""",
		[character_id, limit]
	)
	var out: Array = []
	for row in db.query_result:
		out.append(row.duplicate())
	return out


# Offices currently held by a character. Returns rows shaped:
#   {region_type, region_id, office_key, granted_turn}
func offices_of(character_id: int) -> Array:
	db.query_with_bindings("""
		SELECT region_type, region_id, office_key, granted_turn
		FROM offices
		WHERE holder_character_id = ?
		ORDER BY region_type, office_key;""",
		[character_id]
	)
	var out: Array = []
	for row in db.query_result:
		out.append(row.duplicate())
	return out


# The player's current character — they ARE the head of their faction's
# country tier. For england, that's King Henry; wales, Prince Llywelyn; etc.
# Returns 0 if no holder is recorded (e.g. fresh DB pre-seed).
func player_character_id() -> int:
	var h: Dictionary = holder_of("country", player_faction_id)
	return int(h.get("character_id", 0))


func _short_name(character_id: int) -> String:
	if character_id <= 0:
		return "—"
	var c: Dictionary = character(character_id)
	if c.is_empty():
		return "#%d" % character_id
	return "%s %s" % [str(c.get("given_name", "")), str(c.get("surname", ""))]


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
			death_age INTEGER NOT NULL DEFAULT 60,
			martial INTEGER NOT NULL DEFAULT 5,
			diplomacy INTEGER NOT NULL DEFAULT 5,
			stewardship INTEGER NOT NULL DEFAULT 5,
			intrigue INTEGER NOT NULL DEFAULT 5,
			piety INTEGER NOT NULL DEFAULT 5,
			traits_json TEXT NOT NULL DEFAULT '[]',
			personal_treasury INTEGER NOT NULL DEFAULT 0
		);""")
	# Retinues — each character's standing host. Upkeep is paid every turn
	# out of personal_treasury; unit counts can be edited as players + AI
	# raise/disband troops in future work. One row per character (UNIQUE).
	db.query("""
		CREATE TABLE IF NOT EXISTS retinues (
			character_id INTEGER PRIMARY KEY REFERENCES characters(id),
			foot INTEGER NOT NULL DEFAULT 0,
			archers INTEGER NOT NULL DEFAULT 0,
			cavalry INTEGER NOT NULL DEFAULT 0,
			levy INTEGER NOT NULL DEFAULT 0
		);""")
	# Per-character life events. Birth/coming-of-age/marriage/death-of-spouse/
	# death — driven by the yearly lifecycle tick from advance_turn().
	db.query("""
		CREATE TABLE IF NOT EXISTS lifecycle_events (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			character_id INTEGER NOT NULL REFERENCES characters(id),
			kind TEXT NOT NULL,
			year INTEGER NOT NULL,
			payload_json TEXT NOT NULL DEFAULT '{}'
		);""")
	db.query("CREATE INDEX IF NOT EXISTS idx_lifecycle_character ON lifecycle_events(character_id);")
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
	# Political opinion between two characters. Default 0; positive = friendly,
	# negative = hostile. NOT enforced symmetric — A may admire B even when B
	# disdains A. Stored sparsely: a missing row means "default 0".
	db.query("""
		CREATE TABLE IF NOT EXISTS character_opinions (
			character_id INTEGER NOT NULL REFERENCES characters(id),
			target_id INTEGER NOT NULL REFERENCES characters(id),
			opinion INTEGER NOT NULL DEFAULT 0,
			last_changed_turn INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (character_id, target_id)
		);""")
	# Court offices held by characters. Each (region_type, region_id, office_key)
	# is held by AT MOST one character. Office keys are tier-specific strings
	# like 'marshal','steward','chancellor','spymaster','chaplain'.
	db.query("""
		CREATE TABLE IF NOT EXISTS offices (
			region_type TEXT NOT NULL,
			region_id TEXT NOT NULL,
			office_key TEXT NOT NULL,
			holder_character_id INTEGER REFERENCES characters(id),
			granted_turn INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (region_type, region_id, office_key)
		);""")
	# Action queue. An action is created by one character, may be aimed at
	# another, and may sit pending awaiting that target's response. Payload
	# is opaque JSON so different action types can carry their own fields
	# without schema churn.
	db.query("""
		CREATE TABLE IF NOT EXISTS actions (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			action_type TEXT NOT NULL,
			initiator_id INTEGER NOT NULL REFERENCES characters(id),
			target_id INTEGER REFERENCES characters(id),
			region_type TEXT,
			region_id TEXT,
			payload_json TEXT NOT NULL DEFAULT '{}',
			status TEXT NOT NULL DEFAULT 'pending',
			created_turn INTEGER NOT NULL DEFAULT 0,
			resolved_turn INTEGER,
			resolution_text TEXT
		);""")
	# Hidden character ambitions — every character has at most one. Kinds:
	#   "attain_office"  — wants the named office_key at any region of its tier
	#   "rule_region"    — wants to hold a specific region
	#   "grow_prestige"  — wants to push their family's prestige higher
	# `hidden = 1` until discovered via intrigue (Spymaster / Chaplain rolls
	# are the planned reveal paths). Only the character's own holder and
	# (eventually) the discoverer should see it.
	db.query("""
		CREATE TABLE IF NOT EXISTS character_ambitions (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			character_id INTEGER NOT NULL UNIQUE REFERENCES characters(id),
			kind TEXT NOT NULL,
			target_office_key TEXT,
			target_region_type TEXT,
			target_region_id TEXT,
			set_turn INTEGER NOT NULL DEFAULT 0,
			hidden INTEGER NOT NULL DEFAULT 1
		);""")
	db.query("CREATE INDEX IF NOT EXISTS idx_ambitions_character ON character_ambitions(character_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_characters_family ON characters(family_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_holdings_holder ON holdings(holder_character_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_rel_character ON relationships(character_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_rel_related ON relationships(related_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_opinions_char ON character_opinions(character_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_offices_holder ON offices(holder_character_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_actions_target ON actions(target_id, status);")
	db.query("CREATE INDEX IF NOT EXISTS idx_actions_initiator ON actions(initiator_id);")


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
		var owner_fid: String = factions_by_duchy.get(duchy, "england")
		var garrison: int = int(co.get("garrison", 0))
		# Per-barony fertility (latitude-derived in MapData) gives a better
		# baseline than the old per-duchy constant. We pick the county-level
		# AVERAGE here, then add a small Gaussian shake so even adjacent
		# counties in the same duchy don't open with identical values.
		# fertility_by_duchy is kept as a fallback for sparse data.
		var fert_avg: float = MapData.county_fertility_avg(cname)
		var base_fertility: float = fert_avg if fert_avg > 0.0 else float(fertility_by_duchy.get(duchy, 1.0))
		var fertility: float = clampf(
			GaussianSystem.sample(base_fertility, 0.08),
			0.4, 1.6
		)
		db.query_with_bindings(
			"INSERT OR IGNORE INTO counties_state(county_id, owner_faction_id, garrison, fertility, updated_turn) VALUES(?,?,?,?,?);",
			[cname, owner_fid, garrison, fertility, 0]
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
	# Death age sampled from N(58, 14) clamped to [30, 90]. Already-dead seed
	# characters (e.g. a holder's deceased father) get their current age — the
	# year-tick treats them as already-passed.
	var death_age: int = age
	if alive:
		death_age = int(GaussianSystem.sample_clamped(58.0, 14.0, max(age + 1, 30), 90))
	db.query_with_bindings(
		"INSERT INTO characters(given_name, family_id, title, age, gender, alive, death_age) VALUES(?,?,?,?,?,?,?);",
		[given, family_id, title, max(0, age), gender, 1 if alive else 0, death_age]
	)
	var cid: int = db.get_last_insert_rowid()
	# Backfill a birth event so the lifecycle log starts on day one.
	# Game start is Spring 1247 — every character's birth year = 1247 - age.
	_log_lifecycle(cid, "birth", 1247 - max(0, age), {})
	if not alive:
		# Seed-time deceased characters (a holder's father, usually): they
		# died sometime before the campaign begins. Place the event one year
		# before the start so it's older than any subsequent log entry.
		_log_lifecycle(cid, "death", 1246, {})
	else:
		# Living characters get a hidden ambition — the engine of intrigue.
		# Deterministic per character via a stable hash so the same seed
		# always produces the same ambitions across reruns.
		_generate_ambition(cid)
	return cid


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

	# Offices intentionally start VACANT. Appointments are a lord's
	# prerogative — see GameState.appoint_to_office / vacate_office.
	print("GameState: seeded political layer — %d holdings, %d characters, %d families, %d relationships" % [
		_count("holdings"), _count("characters"), _count("families"),
		_count("relationships")
	])


# Office appointments are a lord's prerogative — never auto-seeded. The
# helpers that used to spawn courtiers have been removed; see
# appoint_to_office / vacate_office / eligible_office_candidates below for
# the player-driven flow.


# ── OFFICE APPOINTMENT API ───────────────────────────────────────────────────

# Appoint `character_id` to (region_type, region_id, office_key). Inserts or
# replaces — every slot holds at most one character. Caller is expected to
# validate eligibility before calling; UI helpers do this via
# eligible_office_candidates.
#
# Args:
#   region_type, region_id, office_key (String): the office slot.
#   character_id (int): who fills the slot. Pass 0 to leave vacant (same as
#       vacate_office).
# Returns: void
func appoint_to_office(region_type: String, region_id: String,
		office_key: String, character_id: int) -> void:
	if character_id <= 0:
		vacate_office(region_type, region_id, office_key)
		return
	# If this slot already had a different holder, log a "dismissed" event
	# for them so the prior officer's history records the loss.
	var prior: Dictionary = office_holder(region_type, region_id, office_key)
	if not prior.is_empty():
		var prior_id: int = int(prior.get("character_id", 0))
		if prior_id > 0 and prior_id != character_id:
			_log_lifecycle(prior_id, "dismissed", current_year(), {
				"office": office_key,
				"region_type": region_type,
				"region_id": region_id,
			})
	db.query_with_bindings("""
		INSERT OR REPLACE INTO offices(region_type, region_id, office_key,
				holder_character_id, granted_turn)
		VALUES(?,?,?,?,?);""",
		[region_type, region_id, office_key, character_id, current_turn()]
	)
	# Log the appointment on the new holder so their History tab shows it.
	_log_lifecycle(character_id, "appointed", current_year(), {
		"office": office_key,
		"region_type": region_type,
		"region_id": region_id,
	})
	state_changed.emit()


# Remove the holder of an office slot, leaving it vacant. Logs a "dismissed"
# lifecycle event on the prior holder so their history reflects the loss.
func vacate_office(region_type: String, region_id: String, office_key: String) -> void:
	var prior: Dictionary = office_holder(region_type, region_id, office_key)
	db.query_with_bindings("""
		DELETE FROM offices
		WHERE region_type = ? AND region_id = ? AND office_key = ?;""",
		[region_type, region_id, office_key]
	)
	if not prior.is_empty():
		var prior_id: int = int(prior.get("character_id", 0))
		if prior_id > 0:
			_log_lifecycle(prior_id, "dismissed", current_year(), {
				"office": office_key,
				"region_type": region_type,
				"region_id": region_id,
			})
	state_changed.emit()


# Candidate pool for `appoint_to_office` at a given region. Returns adult
# living male characters drawn from the region's holder's near social
# circle: their relatives (parents/spouse/siblings/children) and the
# holders of any sub-regions they directly oversee.
#
# Args:
#   region_type, region_id (String).
# Returns:
#   Array of {character_id, given_name, surname, title, age, relation_hint}
#   suitable for an appointment picker list. Empty if region has no holder.
func eligible_office_candidates(region_type: String, region_id: String) -> Array:
	var holder: Dictionary = holder_of(region_type, region_id)
	if holder.is_empty():
		return []
	var holder_id: int = int(holder.get("character_id", 0))
	# Office's tier rank — used to gate candidates by their family standing.
	# A baron's family (tier rank 3) cannot fill a duchy office (tier rank 1):
	# the rule is family_tier_rank <= office_tier_rank ("can't hold a higher
	# office than your station"). Lower number = higher rank in TIER_RANK.
	var office_tier: int = int(TIER_RANK.get(region_type, NO_HOLDING_TIER))
	var family_tiers: Dictionary = _compute_family_tiers()
	var seen: Dictionary = {}
	var out: Array = []

	# 1. The lord's relatives — pulls full stats + family prestige so the
	# appointment UI can show comparable candidates side by side.
	db.query_with_bindings("""
		SELECT r.kind AS relation_hint, c.id AS character_id, c.given_name,
			   c.title, c.age, c.family_id, f.surname, f.prestige,
			   c.martial, c.diplomacy, c.stewardship, c.intrigue, c.piety
		FROM relationships r
		JOIN characters c ON c.id = r.related_id
		LEFT JOIN families f ON f.id = c.family_id
		WHERE r.character_id = ?
		  AND c.alive = 1 AND c.age >= 16
		ORDER BY c.age DESC;""", [holder_id])
	for row in db.query_result:
		var cid: int = int(row["character_id"])
		if seen.has(cid):
			continue
		seen[cid] = true
		out.append({
			"character_id": cid,
			"given_name": str(row["given_name"]),
			"surname": str(row["surname"]),
			"title": str(row["title"]),
			"age": int(row["age"]),
			"family_id": int(row["family_id"]) if row["family_id"] != null else 0,
			"relation_hint": str(row["relation_hint"]),
			"prestige": int(row["prestige"]) if row["prestige"] != null else 0,
			"martial": int(row["martial"]) if row["martial"] != null else 0,
			"diplomacy": int(row["diplomacy"]) if row["diplomacy"] != null else 0,
			"stewardship": int(row["stewardship"]) if row["stewardship"] != null else 0,
			"intrigue": int(row["intrigue"]) if row["intrigue"] != null else 0,
			"piety": int(row["piety"]) if row["piety"] != null else 0,
		})

	# 2. Holders of sub-regions (vassals of this lord). Fetch the full stat
	# block via a second per-character query so the same comparison data is
	# available regardless of which path surfaced the candidate.
	for v in vassals_of(holder_id):
		var cid: int = int(v.get("character_id", 0))
		if cid <= 0 or seen.has(cid):
			continue
		seen[cid] = true
		var detail: Dictionary = character(cid)
		out.append({
			"character_id": cid,
			"given_name": str(v.get("given_name", "")),
			"surname": str(v.get("surname", "")),
			"title": str(v.get("title", "Lord")),
			"age": int(v.get("age", 0)),
			"family_id": int(v.get("family_id", 0)),
			"relation_hint": "vassal",
			"prestige": int(detail.get("prestige", 0)),
			"martial": int(detail.get("martial", 0)),
			"diplomacy": int(detail.get("diplomacy", 0)),
			"stewardship": int(detail.get("stewardship", 0)),
			"intrigue": int(detail.get("intrigue", 0)),
			"piety": int(detail.get("piety", 0)),
		})

	# Tier gate. A candidate is eligible iff their family's highest-held
	# tier rank is at or above (≤ in TIER_RANK numbers) the office's tier.
	# A candidate whose family holds nothing has tier rank = NO_HOLDING_TIER
	# (4) and is rejected for any office above barony.
	var filtered: Array = []
	for cand in out:
		var fid: int = int(cand.get("family_id", 0))
		var ftier: int = int(family_tiers.get(fid, NO_HOLDING_TIER))
		if ftier > office_tier:
			continue
		# Annotate with comparison-only fields the candidate UI needs.
		cand["family_tier"] = ftier
		cand["family_tier_label"] = _tier_label_for_rank(ftier)
		# Opinion the candidate currently has of the appointing lord.
		cand["opinion_of_liege"] = opinion_of(int(cand["character_id"]), holder_id)
		cand["current_office"] = _short_office_for(int(cand["character_id"]))
		filtered.append(cand)
	return filtered


# Compact "M12 D8 S5 I7 P4" style string for a candidate row. Cheap helper so
# the appointment table can render the five stats in one column without
# eating five columns of width. Used by the picker tables in court_panel +
# region_panel.
#
# Args:
#   c (Dictionary): candidate row with martial/diplomacy/stewardship/intrigue/piety.
# Returns:
#   String: glyph-prefixed stat line.
func candidate_stats_brief(c: Dictionary) -> String:
	return "M%d D%d S%d I%d P%d" % [
		int(c.get("martial", 0)), int(c.get("diplomacy", 0)),
		int(c.get("stewardship", 0)), int(c.get("intrigue", 0)),
		int(c.get("piety", 0)),
	]


# Single label for a tier rank value (0..4). Used by the appointment UI's
# Tier column so the player sees "Duke" / "Earl" instead of a bare number.
func _tier_label_for_rank(rank: int) -> String:
	match rank:
		0: return "Crown"
		1: return "Duke"
		2: return "Earl"
		3: return "Baron"
	return "landless"


# Compact human-readable string for whatever single office a character holds
# right now — picks the highest-tier slot if they juggle several. Returns ""
# when they hold none. Used by the appointment comparison table so the
# player can see if the candidate is already occupying a post elsewhere.
func _short_office_for(character_id: int) -> String:
	var slots: Array = offices_of(character_id)
	if slots.is_empty():
		return ""
	# Lower TIER_RANK number = higher tier; pick the topmost.
	var best: Dictionary = slots[0]
	var best_rank: int = int(TIER_RANK.get(str(best.get("region_type", "")), NO_HOLDING_TIER))
	for s in slots:
		var r: int = int(TIER_RANK.get(str(s.get("region_type", "")), NO_HOLDING_TIER))
		if r < best_rank:
			best_rank = r
			best = s
	return "%s of %s" % [
		str(OFFICE_LABELS.get(str(best.get("office_key", "")), str(best.get("office_key", "")))),
		str(best.get("region_id", "")),
	]


# ── AMBITIONS ────────────────────────────────────────────────────────────────
# Every living character carries one hidden ambition that motivates their
# AI behaviour and provides hooks for intrigue. Discovery / reveal flips
# hidden→0 (planned: Spymaster + Chaplain office actions). For now we just
# seed the data; AI driver and discovery rolls land in follow-up turns.

const AMBITION_OFFICE_POOL := [
	"marshal", "chancellor", "spymaster", "chaplain", "treasurer",
	"constable", "seneschal", "herald", "justiciar",
	"sheriff", "coroner", "bailiff", "castellan", "reeve", "forester",
]


# Deterministic ambition for a character. Picks one of three kinds and
# stores it as hidden=1. Idempotent — INSERT OR IGNORE since the UNIQUE
# constraint on character_id will reject duplicates.
func _generate_ambition(character_id: int) -> void:
	var roll: int = _hash_int("ambition", character_id) % 100
	if roll < 60:
		# 60% — attain a specific office at any tier. The actual target
		# region is left null; AI will pick based on what's reachable.
		var idx: int = _hash_int("ambition-office", character_id) % AMBITION_OFFICE_POOL.size()
		var office_key: String = AMBITION_OFFICE_POOL[idx]
		db.query_with_bindings("""
			INSERT OR IGNORE INTO character_ambitions(
				character_id, kind, target_office_key, set_turn, hidden)
			VALUES(?, 'attain_office', ?, ?, 1);""",
			[character_id, office_key, current_turn()]
		)
	elif roll < 85:
		# 25% — grow family prestige. No targets; the AI driver will pick
		# whichever prestige-bumping actions are affordable.
		db.query_with_bindings("""
			INSERT OR IGNORE INTO character_ambitions(
				character_id, kind, set_turn, hidden)
			VALUES(?, 'grow_prestige', ?, 1);""",
			[character_id, current_turn()]
		)
	else:
		# 15% — rule a specific region one tier up from the character's
		# (currently unknown) station. At seed time we don't yet know the
		# character's tier, so we drop just the kind for the AI driver to
		# resolve target later.
		db.query_with_bindings("""
			INSERT OR IGNORE INTO character_ambitions(
				character_id, kind, set_turn, hidden)
			VALUES(?, 'rule_region', ?, 1);""",
			[character_id, current_turn()]
		)


# Read a character's ambition. Returns {} when nothing is recorded, or
# {kind, target_office_key, target_region_type, target_region_id, hidden}
# when one exists. Callers respect `hidden` — UI shouldn't render the
# specifics for hidden ambitions until intrigue reveals them.
func ambition_of(character_id: int) -> Dictionary:
	if character_id <= 0:
		return {}
	db.query_with_bindings("""
		SELECT kind, target_office_key, target_region_type, target_region_id,
			   set_turn, hidden
		FROM character_ambitions
		WHERE character_id = ?
		LIMIT 1;""", [character_id])
	if db.query_result.is_empty():
		return {}
	return db.query_result[0].duplicate()


# Reveal a hidden ambition — used by intrigue discovery actions.
func reveal_ambition(character_id: int) -> void:
	db.query_with_bindings("""
		UPDATE character_ambitions SET hidden = 0 WHERE character_id = ?;""",
		[character_id]
	)
	state_changed.emit()


# Legacy helper retained for completeness — generates a fresh adult male
# character from the regional name pool. NO LONGER CALLED by office seeding;
# kept in case future systems need to spawn courtiers (e.g. faction events
# or claim resolution). Returns the new id, or 0 if pools haven't loaded.
func _spawn_courtier(country_letter: String, office_key: String) -> int:
	if not DesignData.loaded:
		return 0
	var pools: Dictionary = DesignData.name_pools
	var given_pool: Array = pools.get("male", {}).get(country_letter, [])
	if given_pool.is_empty():
		given_pool = pools.get("male", {}).get("E", [])
	var surname_pool: Array = pools.get("surnames", {}).get(country_letter, [])
	if surname_pool.is_empty():
		surname_pool = pools.get("surnames", {}).get("E", [])
	if given_pool.is_empty() or surname_pool.is_empty():
		return 0
	var seed_str: String = "courtier:%s:%s" % [country_letter, office_key]
	var given_name: String = given_pool[_hash_int(seed_str, 1) % given_pool.size()]
	var sn: String = surname_pool[_hash_int(seed_str, 2) % surname_pool.size()]
	var fid: int = _ensure_family(sn, 40)
	var age: int = 28 + (_hash_int(seed_str, 3) % 20)   # 28..47
	var title: String = str(OFFICE_LABELS.get(office_key, "Lord"))
	return _insert_character(given_name, fid, title, age, "male")


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
