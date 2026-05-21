# HANDOFF.md

Captain's log for cross-chat continuity. Read this before doing any work in a fresh session. Update at the end of each session.

**Last touched:** 2026-05-21 (late evening) — Deep-zoom polish: per-barony fill polygons added (county fills hide at barony zoom band, barony fills show), overlay walker now colours each barony individually for Wealth + Fertility, tooltip carries a parent-context line ("In: County · Duchy · Country"), and per-barony fertility is now derived from centroid latitude with a per-duchy richness modifier in `MapData` (replacing the per-duchy hand-typed table as the source of truth). Earlier this evening: parchment background, hover highlight, four-mode overlay, TopBar chips, Ctrl+Tab cycle.

---

## Project model

**Phase 1 — campaign layer for England / Wales / Scotland, 1247.** Godot 4.6 + godot-sqlite v4.7 (Windows `.dll` under `godot/addons/godot-sqlite/bin/`). One working DB at `user://current.db`; slot saves at `user://saves/slot*.db`.

### Data split

| File | Role |
|---|---|
| `godot/data/gb_godot.json` | Immutable geometry / topology (counties, baronies as LAD13CDs). Built by `godot/tools/convert_to_godot.py`. |
| `godot/data/gb_design.json` | Immutable design data (monarchs, earls, dukes, barony holders, economy baselines, name pools). Built by `godot/tools/extract_design.py`. |
| `user://current.db` | Live mutable state — characters, families, holdings, offices, opinions, lifecycle events, ambitions, retinues. |

### Autoload order
`MapSettings → DesignData → MapData → GaussianSystem → GameState`. Always.

### Tier ranks
`TIER_RANK = {country: 0, duchy: 1, county: 2, barony: 3}`. `NO_HOLDING_TIER = 4` (nothing held). Lower number = higher rank.

---

## Current schema (`user://current.db`)

| Table | Purpose | Key columns |
|---|---|---|
| `factions` | Per-country state: treasury, color, monarch. | `id` (PK) |
| `counties_state` | Per-county mutable: garrison, fertility, owner. | `county_id` (PK) |
| `turns` | Per-turn log. | `turn_number` (PK) |
| `harvest_params` | Per-season N(mean, σ) for end-turn rolls. | `season` (PK) |
| `families` | Surname-keyed houses with prestige. | `id` AUTOINCREMENT, `surname` UNIQUE |
| `characters` | Every person. Has `death_age` sampled at insert. | `id` AUTOINCREMENT |
| `holdings` | Region → holder. | `(region_type, region_id)` PK |
| `relationships` | Kin edges: spouse, parent, child, sibling. Bidirectional. | `(character_id, related_id, kind)` UNIQUE |
| `lifecycle_events` | birth / coming_of_age / marriage / widowed / death / inherited / inheritance_blocked / escheated / appointed / dismissed | `id` AUTOINCREMENT |
| `character_opinions` | Asymmetric political opinion, ±100. | `(character_id, target_id)` PK |
| `offices` | Court appointments. **Never auto-filled.** | `(region_type, region_id, office_key)` PK |
| `actions` | Player + AI action queue (pending / accepted / declined). | `id` AUTOINCREMENT |
| `character_ambitions` | Hidden motivation per character. | `character_id` UNIQUE |
| `retinues` | Per-character standing host: foot/archers/cavalry/levy counts. Upkeep computed on read via `UPKEEP_PER_UNIT`. | `character_id` PK |

`characters` table also carries a `personal_treasury INTEGER` column (added in the v2 migration). Negative values mean the lord is in arrears — surfaced in the panel with a red tint.

**`PRAGMA user_version`** sentinels:
- `1` — legacy-sweep complete (offices-courtier wipe; safe to ignore on existing saves).
- `2` — `personal_treasury` column + `retinues` table present. Migration is idempotent: `_ensure_economy_schema` ALTERs only if the column is missing, then bumps to 2.

---

## Per-tier offices (all tier-unique, no overlap)

| Tier | Office keys |
|---|---|
| Country | marshal, chancellor, spymaster, chaplain, treasurer |
| Duchy | constable, seneschal, herald, justiciar |
| County | sheriff, coroner, bailiff |
| Barony | castellan, reeve, forester |

**Office eligibility rule:** candidate's family tier rank must be ≤ office tier rank. Implemented in `GameState.eligible_office_candidates`, which now also annotates each candidate with prestige, all five stats, opinion-of-liege, family-tier label, and currently-held office.

**Office key-stat hint:** office → primary stat lookup (`OFFICE_KEY_STAT`) is duplicated in both `region_panel.gd` and `court_panel.gd`. Surfaced in the picker header as "(key stat: Martial)" so the player knows which Stats column matters.

---

## Folder layout (2026-05-21)

```
godot/
  CampaignMap.tscn + .gd        ← main scene + script (stays at root)
  MainMenu.tscn + main_menu.gd  ← title screen (stays at root)
  project.godot
  addons/godot-sqlite/...
  assets/...
  data/gb_godot.json, gb_design.json
  scripts/                      ← autoloads + heavy data layers
    MapSettings.gd, DesignData.gd, MapData.gd, GaussianSystem.gd, GameState.gd,
    DashedPolygon.gd
  panels/                       ← every modal panel
    character_panel.gd, family_tree_panel.gd, region_panel.gd, court_panel.gd,
    settings_panel.gd, cascading_panel.gd, db_browser.gd
  ui/                           ← cross-cutting UI primitives
    ui_theme.gd (class_name UITheme), ui_panel.gd, top_bar.gd,
    nav_router.gd, data_table.gd
  tools/                        ← offline build scripts
    convert_to_godot.py, extract_design.py
  docs/                         ← design notes (not loaded by Godot)
    Project.md, interactive_*.html, england.html, debug_map.svg
```

Path-sensitive callers updated in the same pass:
- `CampaignMap.tscn` ext_resource paths
- `data_table.gd`, `region_panel.gd`, `court_panel.gd` preloads (`res://ui/data_table.gd`, `res://ui/ui_theme.gd`)
- `MainMenu.tscn` still points at root `main_menu.gd`, which stays there.

The Godot UID system (.gd.uid sidecars moved alongside their .gd) preserves cross-scene references for anything that uses `uid://…` instead of `res://…`.

---

## Panel architecture

All four modals unified at **880×640** with Close (`✕`) pinned top-right. They live under `UI/Control` and brought to front via `move_to_front` on show.

| Panel | Tabs / sections |
|---|---|
| `panels/character_panel.gd` | **Overview** (scrollable; Stats / Lord / Offices / Holdings / Retinue / Vassals on left, Family on right), **History** (lifecycle events with year gutter), **Diplomacy** (Opinion / Actions / Inbox). Footer: 🌳 Family-tree button. |
| `panels/family_tree_panel.gd` | Shogun-2 style: top row = framed FAMILY (parents) + SIBLINGS boxes side-by-side, middle = HOUSE HEAD + spouse, bottom = CHILDREN. ✝ icon + grey style on deceased chips. |
| `panels/region_panel.gd` | **Economy** (totals + sub-region DataTable), **Ownership** (holder card + walked liege chain + vassals DataTable), **Offices** (slots with Appoint/Replace/Dismiss flow + DataTable-based candidate compare picker), **Subregions**. |
| `panels/court_panel.gd` | Header (monarch + Close), Great Offices section with same DataTable picker, Direct Vassals list. |

**Map interaction:**
- **Hover** any region → polygons get a soft warm `HOVER_TINT` modulate (separate from `SELECTED_TINT` so the player can tell the difference at a glance). After 500 ms of stable hover, a rich tooltip appears with name/tier/holder/age/income/population/garrison, plus an "In: …" line walking the parent chain (barony → county → duchy → country, etc.).
- **Click** a region → directly opens `RegionPanel`. The old right-side InfoPanel was removed; `ui_panel.gd` is now a slim CanvasLayer stub that keeps the existing .tscn script reference valid.

**Overlay modes** (driven by `_overlay_mode` in CampaignMap.gd, default = `political`):

| Mode | Colour function | Aggregation at country / duchy zoom | At barony zoom |
|---|---|---|---|
| `political` | Faction colour (England red, Wales green, Scotland blue) from `DesignData.factions_by_duchy`. | n/a — already faction-uniform. | Inherits parent county. |
| `geographic` | Duchy colour from `MapData.duchies[did].color`. | n/a — already duchy-uniform. | Inherits parent county. |
| `fertility` | Lerp `OVERLAY_FERTILITY_LO` (dry yellow) → `OVERLAY_FERTILITY_HI` (lush green) by normalised fertility `(f − 0.5)`. | **Mean** across constituent counties. | **Per-barony** value from `MapData.barony_fertility`. |
| `wealth` | Lerp `OVERLAY_WEALTH_LO` (dark gold) → `OVERLAY_WEALTH_HI` (bright gold) by `income / max_in_band`. | **Sum** across constituent counties. | **Per-barony** income from the polygon's `income` meta; normalised against the richest barony. |

Devastated counties (red wash) are overlaid on `fertility` / `wealth`. `_devastated_lookup()` returns an empty set today — flip it on once the economy rework adds the column.

**Barony-tier fills.** `MapData.build_baronies(..., fill_parent=county_layer)` adds a per-barony `Polygon2D` with `tier="barony"` meta. `_update_label_visibility` toggles county vs barony fills at band 3 — they live in the same node, just one tier is visible at a time.

Repaint triggers: mode change, zoom-band crossing (handled inside `_update_label_visibility`), and `GameState.state_changed` (turn end → fertility shifted).

**Overlay UI:**
- Four chips in the TopBar (👑 Political · 📜 Geographic · 💰 Wealth · 🌾 Fertility). Active chip glows gold; others are dim. Wealth + Fertility chips also display the player faction's running totals (sum income / mean fertility).
- Chips emit `overlay_requested(mode)`; CampaignMap calls `set_overlay_mode` then echoes back to TopBar via `set_active_overlay(mode)` so the chip lights stay in sync.
- **Ctrl+Tab** cycles forward through `OVERLAY_MODES`; **Ctrl+Shift+Tab** reverses. Handled in `_unhandled_input` before the regular keycode match so Tab isn't eaten by Control focus traversal.

**Parchment background:**
- Screen-space tiled `TextureRect` (`stretch_mode = STRETCH_TILE`) inside a `Background` `CanvasLayer` at `layer = -100`, sitting behind the world Node2D. Texture is `assets/page_seamless_01.png`.
- County polygon alpha is `0.88` (down from `1.0` in `MapData.build_county_polygons`) so the parchment grain shows through every overlay mode.

### Cross-panel patterns
- **NavRouter** (`nav_router.gd`, Node under `UI/Control`) owns the back/forward history (max 64). Every open call routes through it. **mouse4 / mouse5** wired in `NavRouter._input` (NOT `CampaignMap._unhandled_input` — panels would swallow it).
- **Tab persistence**: each panel stores `_active_tab` and reconnects `tab_changed` on every `_rebuild` so clicks don't kick the user back to tab 0.
- **Reusable `data_table.gd`** for sortable column tables. Used in Region panel.
- **`UITheme`** (`ui_theme.gd`, `class_name UITheme extends RefCounted`) holds palette + stylebox builders. Every modal calls `UITheme.style_panel(self)` in `_ready`.

---

## Lifecycle simulation

`_advance_lifecycle(year)` fires on the Spring transition (turn > 1 AND `(next - 1) % 4 == 0`). Order:
1. Age all alive characters by 1.
2. Coming-of-age events at exactly age 16.
3. Deaths (`age >= death_age` → `alive=0`, log death, widow spouse, run `_process_succession` per holding).
4. Marriage matching: hierarchy-aware (tier preference bands `[0, -1, +1, -2, +2, …]`), AGE_GAP_MAX=12, MARRIAGES_PER_YEAR=60.
5. `_spawn_partner_fallback` for unwed barony-tier holders at age 30+ (generates a deterministic partner from the regional name pool — **only at barony tier**).
6. `_spawn_children` — per couple, mother 16–45, father 18–70, 22% base chance (×0.6 for mothers >35).

**Succession**: eldest living male child → eldest living male sibling → escheat. Heir's prior holdings escheat to their respective lieges (the "relocate to new post" behaviour). Liege block roll: `15% × tier-step` when the heir would climb tiers.

**Headless sim hook**: `++ --sim-years=N` (or env `MEDIEVAL_SIM_YEARS=N`) on the Godot CLI runs N years of lifecycle and quits.

---

## Actions + prestige + side-effects

`ACTION_CATALOG` (in `GameState.gd`) declares every action with: `label`, `direction` (up/down/peer/self), `resolution` (immediate/reply), `prestige_cost`, optional `requires_office`, optional `on_accept_opinion` / `on_decline_opinion`.

`resolve_action` now dispatches to `_apply_action_side_effects(action_type, actor, target, payload)` on accept. Mechanical effects per type:

| Action | Effect on accept (in addition to opinion shift) |
|---|---|
| `appoint_office` | If payload carries `{office_key, region_type, region_id}`: writes to `offices` via `appoint_to_office` (eligibility re-checked). Without payload, resolution text says "appointment skipped — use Court/Region panel." |
| `grant_aid` | Cross-faction: gold transfer via `adjust_treasury`. Same-faction: +5 prestige to target's house. |
| `levy_special_tax` | Actor faction +gold, target family –5 prestige. |
| `sponsor_works` | Actor faction –gold, target family +8 prestige. (Region income buff pending.) |
| `excommunicate` | Target family –25 prestige, plus the catalog's –50 opinion. |
| `bless_marriage` | Target family +5 prestige. |
| `swear_fealty` | Actor family +3 prestige. |
| `request_marriage`, `forge_alliance`, `sue_for_peace`, `declare_war`, `spy_on_court`, `raise_levy` | Opinion / prestige flow only — resolution text flags "no mechanical effect yet (system pending)." |

**Prestige is a per-family budget**, decremented on `submit_action`. No regeneration yet — still WIP.

Two key read APIs:
- `actions_for(cid)` — every action this character qualifies for, filtered by office only. Used by the "Actions available to …" display.
- `available_actions(actor, target)` — direction-filtered. Used by "Your actions toward them" (player → subject).

---

## Economy + retinue (NEW 2026-05-21)

- **Global income ×5 multiplier** applied at `MapData._merge_design_overlay` time (`MapData.INCOME_MULTIPLIER`). Garrison + population unchanged. One knob to retune the money supply.
- **`retinues` table** — `character_id` PK + `foot`/`archers`/`cavalry`/`levy` counts. Default counts seeded by holding tier (monarchs 200+50+25+10; dukes 60+20+8+5; counts 25+8+3+3; barons 8+3+1+2; landless 0).
- **Upkeep per turn**: `UPKEEP_PER_UNIT = {foot:1, archers:2, cavalry:4, levy:1}`.
- **Per-character end-of-turn tick** (`_advance_personal_economy`, runs every turn in `advance_turn`):
  1. Sum 25% of every holding's gross income → personal_treasury.
  2. Subtract retinue upkeep from personal_treasury.
  3. Treasury can go negative — visualised red in `CharacterPanel`'s Retinue section.
- **Schema migration v1→v2** (`_ensure_economy_schema`): idempotent ALTER + sentinel bump. Fresh DBs bypass the ALTER entirely.

---

## Ambitions (newly added)

`character_ambitions` table. Every alive character has at most one. Three kinds:
- `attain_office` (60%) — `target_office_key` populated
- `grow_prestige` (25%)
- `rule_region` (15%) — `target_region_*` left null for the AI driver to fill

`hidden = 1` by default. `_ensure_ambitions_seeded()` back-fills on resume (idempotent via UNIQUE constraint on character_id). New characters get one in `_insert_character`.

---

## Code style

- Function-level comments with input/output types (project convention from CLAUDE.md).
- After every prompt, suggest follow-up improvements.
- Finish each session with a commit message in the project's standard format.
- All panel modals must be ESC-closeable (consume via `_input` + `accept_event`).
- Use `UITheme.styled_button`, `UITheme.text_label`, `UITheme.dim_label`, `UITheme.section_header` for visual consistency.

---

## Fertility model (2026-05-21 late evening)

Per-barony fertility is now the source of truth, derived from each barony's centroid Y position:

```
t       = (centroid_y - island_y_min) / (island_y_max - island_y_min)   # 0=north, 1=south
base    = lerp(NORTH_FERTILITY=0.55, SOUTH_FERTILITY=1.30, t)
final   = base × FERTILITY_DUCHY_MOD[duchy_id]
```

`FERTILITY_DUCHY_MOD` lives in `MapData.gd` and carries small designer adjustments around 1.0 (Norfolk +10% for fen, Gloucester +8% for Severn Vale, Highlands -15% for harshness, Gwynedd -8% for Snowdonia, etc.). The latitude curve does the heavy lifting; the modifier expresses character.

Per-county fertility (`counties_state.fertility`, what the per-turn harvest uses) is seeded as the **mean** of constituent baronies' fertility via `MapData.county_fertility_avg`. The legacy `DesignData.fertility_by_duchy` dict is kept only as a fallback when MapData data is missing.

To get the new values on an existing save, delete `user://current.db` (or click "New Game") — the migration is a re-seed, not a column add.

---

## Economy rework (NEXT — explicitly paused this session)

The user has flagged the economy needs a re-design: "treasury etc. doesnt make any sense. Needs to be allocated properly." Retinue / troop counts are also slated to be replaced with lord-specific troop types. Don't extend the current `_advance_personal_economy` or `retinues` model — just leave it ticking until the rework starts.

Two hooks already in place for that work:
- `_devastated_lookup()` in CampaignMap.gd — currently returns `{}`. Add a `devastated` column (or its equivalent) to `counties_state`, query it here, and the red overlay wash + "no yield" semantics light up automatically.
- `faction_economy_summary(faction_id)` in GameState.gd — single-call summary used by the TopBar chips. Extend as needed (e.g. add `total_upkeep`, `net_per_turn`).

---

## WIP (carries between chats)

- **AI ambition driver still TODO.** Characters carry hidden ambitions but nothing acts on them yet. Next step: in `_advance_lifecycle`, characters with `attain_office` ambitions periodically submit `appoint_office` requests (now meaningful! — payload-aware).
- **Intrigue / discovery layer.** Plan: `character_knowledge` table (knower_id, target_id, fact_kind, payload, learned_turn). Spymaster `spy_on_court` rolls vs target intrigue → on success, INSERT a knowledge row that reveals one hidden ambition.
- **`block_appointment` and `prevent_marriage` actions.** When accepted, register a one-year veto on the corresponding event.
- **Ambition reveal in CharacterPanel** — once `hidden = 0`, render a small "Ambitions" section under the header.
- **Prestige regeneration tick** — currently actions only debit. Per-year refill proportional to holdings income, capped at 100.
- **Action UI doesn't yet collect `appoint_office` payload.** The action side-effect respects payload `{office_key, region_type, region_id}` but no UI gathers those when submitting from the Diplomacy tab. For now the direct Court/Region panel picker is the canonical appointment path; the action surfaces "appointment skipped" if invoked without payload.
- **Raise/disband retinue UI** — the table is in place and upkeep ticks every turn, but the player can't change unit counts yet. Needs a `_recruit_unit(character_id, kind, n)` + spend gold from personal_treasury.
- **Region income buff from `sponsor_works`** — currently logs prestige only; should boost the target county's income next harvest tick.
- **End-of-year chronicle popup** showing the year's lifecycle events.
- **Older overlays (DbBrowser / SettingsPanel / CascadingPanel) still use the original opaque stylebox** — needs a UITheme pass.
- **DataTable column resize** handles for longer region names.
- **`OFFICE_KEY_STAT` lookup is duplicated** in `region_panel.gd` and `court_panel.gd`. Worth moving to `ui/ui_theme.gd` or a small shared util once a third caller appears.

---

## Known bugs / friction

- **Cold-start hotspot**: `Geometry2D.decompose_polygon_in_convex` runs every load (~210 ms). Could be precomputed in `convert_to_godot.py` and shipped in `gb_godot.json`.
- **Family tree may need its own scroll** if a character has many children — currently doesn't scroll, but I haven't seen overflow yet.
- **Long Godot editor processes hold the DB file lock** — manual `current.db` deletion requires closing the editor first.

---

## Recent design decisions

- **2026-05-21 (late evening)**: Per-barony fill polygons; county fills hide at the deep-zoom band and barony fills show. Wealth overlay normalises against the richest single barony; Fertility overlay uses per-barony values derived from centroid latitude × duchy richness modifier.
- **2026-05-21 (late evening)**: Tooltip carries an "In: County · Duchy · Country" line walking up the territorial chain from whatever tier is hovered.
- **2026-05-21 (late evening)**: Fertility model moved from per-duchy hand-typed (`DesignData.fertility_by_duchy`) to per-barony centroid-derived (`MapData._compute_barony_fertility`). County fertility seeds as the mean. Legacy dict survives as a fallback only.
- **2026-05-21 (evening)**: Hover modulate (`HOVER_TINT`) added per-polygon; widens with zoom band (hovering a country lights up every county in that country, etc.). Distinct from `SELECTED_TINT` and never overrides it.
- **2026-05-21 (evening)**: Overlay-mode system — Political (default) / Geographic / Fertility / Wealth — with zoom-band aggregation. Country/duchy zoom aggregates the constituent counties (sum for wealth, mean for fertility). Devastation red wash is plumbed but the data hook is a stub until the economy rework.
- **2026-05-21 (evening)**: Faction economy chips in TopBar (💰 income, 🌾 fertility) double as overlay switchers. Ctrl+Tab cycles modes; chip click sets directly.
- **2026-05-21 (evening)**: Parchment background — screen-space tiled `TextureRect` at CanvasLayer `layer = -100`. Polygon alpha dropped to 0.88 so grain shows through.
- **2026-05-21 (PM)**: Right-side InfoPanel removed. Map clicks open `RegionPanel` directly; long-hover (~500 ms) shows a rich tooltip with the info the InfoPanel used to carry. `ui_panel.gd` is now a slim stub script kept for scene-script compatibility.
- **2026-05-21 (PM)**: DataTable first-click defaults to DESCENDING (largest-first is the answer the player usually wants for income/age/garrison). Subsequent clicks toggle.
- **2026-05-21 (PM)**: Office appointment picker upgraded to a sortable comparison DataTable — Name, Age, House, Tier, Prestige, compact M/D/S/I/P stats, opinion-of-liege, current office. Picker header surfaces the office's "key stat" so the player knows which column matters.
- **2026-05-21 (PM)**: `resolve_action` dispatches per-type side-effects (see Actions table above). `appoint_office` now actually appoints when payload is sufficient — was the named complaint.
- **2026-05-21 (PM)**: CharacterPanel Overview adds a **Lord** section between Stats and Offices, walking `liege_of` upward; and a **Retinue** section after Holdings showing troop counts + upkeep + personal_treasury (red when negative).
- **2026-05-21 (PM)**: Income ×5 baseline bump + `retinues` table + `personal_treasury` column. End-turn personal economy tick credits 25% of holding income to personal_treasury and pays upkeep. Schema migration v1→v2 is idempotent.
- **2026-05-21 (PM)**: Folder reorg — `godot/{panels,ui,tools,docs}/` plus existing `scripts/` (autoloads). `CampaignMap.gd/.tscn` + `MainMenu.tscn`/`main_menu.gd` stay at the godot root.
- **2026-05-21 (AM)**: Office eligibility is per-family-tier, not per-character-tier.
- **2026-05-20**: Offices NEVER auto-spawn; appointment is always a lord's prerogative via the Court/Region panel UI. One-shot legacy sweep via `PRAGMA user_version = 1` cleared earlier auto-seeded courtiers.
- **2026-05-20**: All four modals unified to 880×640 with Close at top-right; NavRouter wired to mouse4/mouse5 via `_input` (not `_unhandled_input`).
- **2026-05-20**: Office sets are tier-unique (no key appears in two tiers). Renamed the country tier's `steward` → `treasurer` to match.
- **2026-05-19**: Lifecycle aging is yearly, on Spring transitions. Children inherit the father's surname (patrilineal). Death ages sampled from N(58, 14) clamped [30, 90].
- **2026-05-18**: Heir relocates on inheritance (their prior holdings escheat to their respective lieges).
