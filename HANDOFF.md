# HANDOFF.md

Captain's log for cross-chat continuity. Read this before doing any work in a fresh session. Update at the end of each session.

**Last touched:** 2026-05-21 — Office eligibility tier-gate + barony-name display in CharacterPanel + this handoff file. Working in `godot/scripts/GameState.gd` (eligibility) and `godot/character_panel.gd` (display).

---

## Project model

**Phase 1 — campaign layer for England / Wales / Scotland, 1247.** Godot 4.6 + godot-sqlite v4.7 (Windows `.dll` under `godot/addons/godot-sqlite/bin/`). One working DB at `user://current.db`; slot saves at `user://saves/slot*.db`.

### Data split

| File | Role |
|---|---|
| `data/gb_godot.json` | Immutable geometry / topology (counties, baronies as LAD13CDs). Built by `convert_to_godot.py`. |
| `data/gb_design.json` | Immutable design data (monarchs, earls, dukes, barony holders, economy baselines, name pools). Built by `extract_design.py`. |
| `user://current.db` | Live mutable state — characters, families, holdings, offices, opinions, lifecycle events, ambitions. |

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

**`PRAGMA user_version = 1`** is the legacy-sweep sentinel (offices-courtier wipe was done; do not re-run that on existing saves).

---

## Per-tier offices (all tier-unique, no overlap)

| Tier | Office keys |
|---|---|
| Country | marshal, chancellor, spymaster, chaplain, treasurer |
| Duchy | constable, seneschal, herald, justiciar |
| County | sheriff, coroner, bailiff |
| Barony | castellan, reeve, forester |

**Office eligibility rule (just landed):** candidate's family tier rank must be ≤ office tier rank (i.e. family must be at least as high as the office). Implemented in `GameState.eligible_office_candidates`.

---

## Panel architecture

All four modals unified at **880×640** with Close (`✕`) pinned top-right. They live under `UI/Control` and brought to front via `move_to_front` on show.

| Panel | Tabs / sections |
|---|---|
| `character_panel.gd` | **Overview** (scrollable; Stats / Offices / Holdings / Vassals on left, Family on right), **History** (lifecycle events with year gutter), **Diplomacy** (Opinion / Actions / Inbox). Footer: 🌳 Family-tree button. |
| `family_tree_panel.gd` | Shogun-2 style: top row = framed FAMILY (parents) + SIBLINGS boxes side-by-side, middle = HOUSE HEAD + spouse, bottom = CHILDREN. ✝ icon + grey style on deceased chips. |
| `region_panel.gd` | **Economy** (totals + sub-region DataTable), **Ownership** (holder card + walked liege chain + vassals DataTable), **Offices** (slots with Appoint/Replace/Dismiss flow + inline picker), **Subregions**. |
| `court_panel.gd` | Header (monarch + Close), Great Offices section with same Appoint/Replace/Dismiss flow, Direct Vassals list. |

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

## Actions + prestige

`ACTION_CATALOG` (in `GameState.gd`) declares every action with: `label`, `direction` (up/down/peer/self), `resolution` (immediate/reply), `prestige_cost`, optional `requires_office`, optional `on_accept_opinion` / `on_decline_opinion`.

Currently:
- **Base actions**: request_marriage, grant_aid, appoint_office, swear_fealty.
- **Office-gated**: raise_levy, declare_war (marshal); levy_special_tax, sponsor_works (treasurer); forge_alliance, sue_for_peace (chancellor); spy_on_court (spymaster); bless_marriage, excommunicate (chaplain).

**Prestige is a per-family budget**, decremented on `submit_action`. No regeneration yet — that's WIP.

Two key read APIs:
- `actions_for(cid)` — every action this character qualifies for, filtered by office only. Used by the "Actions available to …" display.
- `available_actions(actor, target)` — direction-filtered. Used by "Your actions toward them" (player → subject).

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

## WIP (carries between chats)

- **Hidden ambitions schema in place; AI driver still TODO.** Characters carry ambitions but nothing acts on them yet. Next step: in `_advance_lifecycle`, characters with `attain_office` ambitions periodically submit `appoint_office` requests targeted at appropriate lieges (or `request_marriage` if angling for a rival's family).
- **Intrigue / discovery layer.** Plan: `character_knowledge` table (knower_id, target_id, fact_kind, payload, learned_turn). Spymaster `spy_on_court` rolls vs target intrigue → on success, INSERT a knowledge row that reveals one hidden ambition.
- **`block_appointment` and `prevent_marriage` actions.** When accepted, register a one-year veto on the corresponding event.
- **Ambition reveal in CharacterPanel** — once `hidden = 0`, render a small "Ambitions" section under the header.
- **Prestige regeneration tick** — currently actions only debit. Per-year refill proportional to holdings income, capped at 100.
- **`appoint_office` *action* side-effect** — currently the action only adjusts opinion. The direct UI flow via Court / Region panels works (`appoint_to_office`). The action-system version should also write to the offices table on accept.
- **End-of-year chronicle popup** showing the year's lifecycle events.
- **Older overlays (DbBrowser / SettingsPanel / CascadingPanel) still use the original opaque stylebox** — needs a UITheme pass.
- **DataTable column resize** handles for longer region names.

---

## Known bugs / friction

- **Cold-start hotspot**: `Geometry2D.decompose_polygon_in_convex` runs every load (~210 ms). Could be precomputed in `convert_to_godot.py` and shipped in `gb_godot.json`.
- **Family tree may need its own scroll** if a character has many children — currently doesn't scroll, but I haven't seen overflow yet.
- **Long Godot editor processes hold the DB file lock** — manual `current.db` deletion requires closing the editor first.

---

## Recent design decisions

- **2026-05-21**: Office eligibility is per-family-tier, not per-character-tier (a non-holder's "rank" is taken from their family's best holding). Barons cannot fill duchy/country offices, etc.
- **2026-05-20**: Offices NEVER auto-spawn; appointment is always a lord's prerogative via the Court/Region panel UI. One-shot legacy sweep via `PRAGMA user_version = 1` cleared earlier auto-seeded courtiers.
- **2026-05-20**: All four modals unified to 880×640 with Close at top-right; NavRouter wired to mouse4/mouse5 via `_input` (not `_unhandled_input`).
- **2026-05-20**: Office sets are tier-unique (no key appears in two tiers). Renamed the country tier's `steward` → `treasurer` to match.
- **2026-05-19**: Lifecycle aging is yearly, on Spring transitions. Children inherit the father's surname (patrilineal). Death ages sampled from N(58, 14) clamped [30, 90].
- **2026-05-18**: Heir relocates on inheritance (their prior holdings escheat to their respective lieges).
