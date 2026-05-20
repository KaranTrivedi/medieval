"""
extract_design.py
Writes data/gb_design.json — all hand-authored "game design" data,
keeping the geometry pipeline (convert_to_godot.py) free of design values.

NEW DATA MODEL (per user request 2026-05-20):
  - DUCHIES: ONLY structural fields (name, color, lord). No economy data.
  - COUNTIES: ONLY `earl`. No income/garrison/population — derived upward
    from baronies.
  - BARONIES: SOURCE OF TRUTH for income/garrison/population, keyed by
    LAD13CD. County totals = SUM(barony values); duchy totals = SUM of its
    counties; country totals = SUM of its duchies.

  Designer flow:
    1. Set COUNTY_BASELINE targets (rough total per county).
    2. Set BARONY_OVERRIDES for specific LADs you have real data for.
    3. The remaining baronies get a deterministic per-LAD slice of the
       county baseline (with ±25% variation derived from a hash of the
       LAD code — same input always → same output, so saves stay stable).

Run from godot/ AFTER convert_to_godot.py has been run (we read the
generated gb_godot.json to learn which LADs belong to which county):
    python extract_design.py
"""

import json
import os
import hashlib

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_GEOMETRY = os.path.join(SCRIPT_DIR, "data", "gb_godot.json")
OUTPUT_PATH = os.path.join(SCRIPT_DIR, "data", "gb_design.json")

# ── DUCHIES — display name, heraldic colour, current lord ────────────────────
DUCHY_DESIGN = {
    'lancaster':   {'name':'Duchy of Lancaster','color':'#5a1212','lord':'Richard of Cornwall'},
    'chester':     {'name':'Earldom of Chester','color':'#3a1050','lord':'John de Lacy'},
    'march':       {'name':'Welsh Marches','color':'#3a2800','lord':'Wm. de Cantilupe'},
    'gloucester':  {'name':'Duchy of Gloucester','color':'#122a60','lord':'Roger Bigod'},
    'norfolk':     {'name':'Earldom of Norfolk','color':'#4a3200','lord':'Hugh Bigod'},
    'cornwall':    {'name':'Duchy of Cornwall','color':'#0e4028','lord':'Richard de Clare'},
    'gwynedd':     {'name':'Kingdom of Gwynedd','color':'#1f5024','lord':'Llywelyn ap Gruffudd'},
    'deheubarth':  {'name':'Kingdom of Deheubarth','color':'#2e6024','lord':'Maredudd ap Owain'},
    'morgannwg':   {'name':'Lordship of Morgannwg','color':'#5a3818','lord':'Richard de Clare'},
    'highlands':   {'name':'Earldom of Ross & Isles','color':'#244266','lord':'William, Earl of Ross'},
    'moray':       {'name':'Earldom of Moray','color':'#1a3a5a','lord':'Alexander Comyn'},
    'lothian':     {'name':'Crown Lands of Lothian','color':'#4a4a14','lord':'Alexander II'},
}

# ── COUNTIES — earl ONLY ─────────────────────────────────────────────────────
# Income / garrison / population are NOT stored at this tier anymore — they
# get computed up from the baronies at runtime. See COUNTY_BASELINE below
# for the designer-friendly "target total" knobs that drive the per-barony
# distribution.
COUNTY_DESIGN = {
    'Northumberland': {'earl':'Henry de Percy'},
    'Durham':         {'earl':'Prince-Bishop'},
    'Cumberland':     {'earl':'Ranulf de Dacre'},
    'Westmorland':    {'earl':'Robert de Clifford'},
    'Lancashire':     {'earl':'Thomas de Lancaster'},
    'Yorkshire':      {'earl':'Robert de Percy'},
    'Cheshire':       {'earl':'John de Lacy'},
    'Derbyshire':     {'earl':'Wm. de Ferrers'},
    'Nottinghamshire':{'earl':'Roger de Mortimer'},
    'Lincolnshire':   {'earl':'Ranulf de Blondeville'},
    'Staffordshire':  {'earl':'Robert de Stafford'},
    'Leicestershire': {'earl':'Simon de Montfort'},
    'Shropshire':     {'earl':'FitzAlan'},
    'Herefordshire':  {'earl':'Humphrey de Bohun'},
    'Worcestershire': {'earl':'Wm. de Beauchamp'},
    'Warwickshire':   {'earl':'Henry de Hastings'},
    'Gloucestershire':{'earl':'Richard de Clare'},
    'Oxfordshire':    {'earl':'Roger de Vere'},
    'Buckinghamshire':{'earl':'Walter Giffard'},
    'Northamptonshire':{'earl':'Saher de Quincy'},
    'Bedfordshire':   {'earl':'Roger de Beauchamp'},
    'Norfolk':        {'earl':'Roger Bigod'},
    'Suffolk':        {'earl':'Hugh Bigod'},
    'Essex':          {'earl':'Geoff. de Mandeville'},
    'Cambridgeshire': {'earl':'John de Burgh'},
    'Hertfordshire':  {'earl':'Roger de Tony'},
    'Middlesex':      {'earl':'Crown Direct (London)'},
    'Kent':           {'earl':'Hubert de Burgh'},
    'Surrey':         {'earl':'John de Warenne'},
    'Sussex':         {'earl':'John de Braose'},
    'Berkshire':      {'earl':'Crown Direct'},
    'Hampshire':      {'earl':'Baldwin de Reviers'},
    'Wiltshire':      {'earl':'Patrick de Chaworth'},
    'Dorset':         {'earl':'Wm. de Mandeville'},
    'Somerset':       {'earl':'Roger de Clifford'},
    'Devon':          {'earl':'Hugh de Courtenay'},
    'Cornwall':       {'earl':'Richard of Cornwall'},
    'Gwynedd':        {'earl':'Llywelyn ap Gruffudd'},
    'Perfeddwlad':    {'earl':'Dafydd ap Gruffudd'},
    'Powys':          {'earl':'Gruffudd Maelor'},
    'Ceredigion':     {'earl':'Maredudd ap Owain'},
    'Dyfed':          {'earl':'Rhys ap Maredudd'},
    'Gower':          {'earl':'John de Mowbray'},
    'Glamorgan':      {'earl':'Richard de Clare'},
    'Gwent':          {'earl':'Humphrey de Bohun'},
    'Highland':       {'earl':'William, Earl of Ross'},
    'Argyll':         {'earl':'Eóghan of Lorn'},
    'Orkney':         {'earl':'Magnus, Jarl of Orkney'},
    'Moray':          {'earl':'Alexander Comyn'},
    'Strathearn':     {'earl':'Malise II of Strathearn'},
    'Fife':           {'earl':'Malcolm, Earl of Fife'},
    'Lothian':        {'earl':'Crown Direct (Alexander II)'},
    'Borders':        {'earl':'Walter Comyn'},
    'Strathclyde':    {'earl':'Maldouen, Earl of Lennox'},
    'Galloway':       {'earl':'Dervorguilla of Galloway'},
}


# ── COUNTY BASELINE TARGETS ─────────────────────────────────────────────────
# Designer knobs: "what should this county TOTAL roughly look like?" These
# are the targets the per-barony distributor aims for. The actual computed
# county total = SUM of its baronies, which will be CLOSE to these numbers
# but not exact — the per-LAD ±25% variation guarantees neighbours feel
# different.
#
# When a county is hand-tweaked here, every barony in it shifts proportionally
# on the next extract_design.py run. Per-LAD overrides in BARONY_OVERRIDES
# take precedence and stay fixed.
COUNTY_BASELINE = {
    'Northumberland': {'income':240,'garrison':280,'population':42000},
    'Durham':         {'income':310,'garrison':220,'population':38000},
    'Cumberland':     {'income':195,'garrison':180,'population':31000},
    'Westmorland':    {'income':160,'garrison':140,'population':22000},
    'Lancashire':     {'income':285,'garrison':240,'population':55000},
    'Yorkshire':      {'income':420,'garrison':350,'population':82000},
    'Cheshire':       {'income':220,'garrison':200,'population':48000},
    'Derbyshire':     {'income':195,'garrison':170,'population':44000},
    'Nottinghamshire':{'income':210,'garrison':180,'population':46000},
    'Lincolnshire':   {'income':310,'garrison':260,'population':68000},
    'Staffordshire':  {'income':185,'garrison':155,'population':40000},
    'Leicestershire': {'income':240,'garrison':195,'population':52000},
    'Shropshire':     {'income':165,'garrison':185,'population':35000},
    'Herefordshire':  {'income':155,'garrison':170,'population':30000},
    'Worcestershire': {'income':195,'garrison':155,'population':42000},
    'Warwickshire':   {'income':225,'garrison':180,'population':50000},
    'Gloucestershire':{'income':280,'garrison':220,'population':58000},
    'Oxfordshire':    {'income':260,'garrison':195,'population':54000},
    'Buckinghamshire':{'income':205,'garrison':165,'population':44000},
    'Northamptonshire':{'income':215,'garrison':175,'population':48000},
    'Bedfordshire':   {'income':170,'garrison':140,'population':35000},
    'Norfolk':        {'income':340,'garrison':270,'population':72000},
    'Suffolk':        {'income':295,'garrison':235,'population':62000},
    'Essex':          {'income':310,'garrison':240,'population':66000},
    'Cambridgeshire': {'income':235,'garrison':185,'population':50000},
    'Hertfordshire':  {'income':200,'garrison':155,'population':42000},
    'Middlesex':      {'income':480,'garrison':380,'population':95000},
    'Kent':           {'income':360,'garrison':290,'population':74000},
    'Surrey':         {'income':245,'garrison':185,'population':50000},
    'Sussex':         {'income':225,'garrison':185,'population':48000},
    'Berkshire':      {'income':200,'garrison':150,'population':38000},
    'Hampshire':      {'income':265,'garrison':205,'population':56000},
    'Wiltshire':      {'income':205,'garrison':165,'population':44000},
    'Dorset':         {'income':180,'garrison':145,'population':36000},
    'Somerset':       {'income':220,'garrison':175,'population':46000},
    'Devon':          {'income':195,'garrison':160,'population':40000},
    'Cornwall':       {'income':285,'garrison':210,'population':52000},
    'Gwynedd':        {'income':95,'garrison':220,'population':22000},
    'Perfeddwlad':    {'income':70,'garrison':140,'population':18000},
    'Powys':          {'income':65,'garrison':120,'population':15000},
    'Ceredigion':     {'income':55,'garrison':95,'population':11000},
    'Dyfed':          {'income':75,'garrison':120,'population':16000},
    'Gower':          {'income':95,'garrison':150,'population':17000},
    'Glamorgan':      {'income':155,'garrison':210,'population':26000},
    'Gwent':          {'income':110,'garrison':170,'population':19000},
    'Highland':       {'income':85,'garrison':220,'population':24000},
    'Argyll':         {'income':95,'garrison':190,'population':19000},
    'Orkney':         {'income':55,'garrison':90,'population':9000},
    'Moray':          {'income':140,'garrison':190,'population':30000},
    'Strathearn':     {'income':145,'garrison':180,'population':32000},
    'Fife':           {'income':160,'garrison':180,'population':36000},
    'Lothian':        {'income':215,'garrison':250,'population':46000},
    'Borders':        {'income':115,'garrison':190,'population':25000},
    'Strathclyde':    {'income':185,'garrison':210,'population':40000},
    'Galloway':       {'income':125,'garrison':175,'population':27000},
}

# ── FERTILITY (baseline; per-county Gaussian noise added at seed time) ───────
FERTILITY_BY_DUCHY = {
    'lancaster':  0.82, 'chester':    0.95, 'march':      0.88,
    'gloucester': 1.08, 'norfolk':    1.22, 'cornwall':   1.00,
    'gwynedd':    0.78, 'powys':      0.82, 'deheubarth': 0.92,
    'glamorgan':  0.95,
    # Welsh duchy id used by the geometry pipeline
    'morgannwg':  0.95,
    # Scottish
    'highlands':  0.65, 'moray':      0.85, 'strathearn': 0.92,
    'lothian':    1.05, 'galloway':   0.82
}

# ── MONARCHS — head of state per country/faction ─────────────────────────────
# Each entry seeds one royal family + the current monarch character.
# Successor logic + family tree expansion come in later phases.
MONARCHS = {
    "england":  {"given": "Henry",     "surname": "Plantagenet", "title": "King",   "age": 39},
    "wales":    {"given": "Llywelyn",  "surname": "ap Iorwerth", "title": "Prince", "age": 24},
    "scotland": {"given": "Alexander", "surname": "Dunkeld",     "title": "King",   "age": 49},
}

# Anglo-Norman / Welsh / Scottish given-name pools, used for deterministic
# barony-baron generation. Each LAD picks one name via a hash of its code.
_GIVEN_NAMES = {
    "E": ["William", "Robert", "John", "Henry", "Geoffrey", "Hugh",
          "Walter", "Roger", "Richard", "Thomas", "Ralph", "Simon"],
    "W": ["Llywelyn", "Dafydd", "Gruffudd", "Rhys", "Maredudd", "Owain",
          "Cadwgan", "Bleddyn", "Iorwerth", "Hywel"],
    "S": ["Alexander", "William", "Robert", "John", "Donald", "Malcolm",
          "Hugh", "Walter", "Patrick", "Duncan"],
}

# Per-country surname particle for generated barons. Real medieval naming was
# all over the place; these are placeholders the user can hand-override.
_SURNAME_PARTICLE = {"E": "de ", "W": "ap ", "S": "of "}


def _pick_name(lad_code, lad_name):
    """Deterministic baron given+surname from an LAD code."""
    country_prefix = lad_code[0] if lad_code else "E"
    pool = _GIVEN_NAMES.get(country_prefix, _GIVEN_NAMES["E"])
    n = int(hashlib.md5(lad_code.encode("utf-8")).hexdigest()[:8], 16)
    given = pool[n % len(pool)]
    # Strip common district-suffix noise from LAD13NM for surname seed.
    base = lad_name.replace(" District", "").replace(" City", "").strip()
    # Drop trailing "and Bute" / parenthetical bits — they read odd in family names.
    if " and " in base:
        base = base.split(" and ", 1)[0]
    if " " in base:
        # Take first word — feels more like a place name.
        base = base.split(" ", 1)[0]
    surname = _SURNAME_PARTICLE.get(country_prefix, "de ") + base
    return {"given": given, "surname": surname, "title": "Baron", "age": 30 + (n % 30)}


def build_barony_holders(geometry):
    """Produce {LAD13CD: {given, surname, title, age}} for every barony.

    Real per-LAD authoring goes in BARONY_OVERRIDES (later, alongside the
    economy overrides). For now, every barony gets a deterministic baron.
    """
    holders = {}
    for county_data in geometry.get("counties", {}).values():
        for b in county_data.get("baronies", []):
            lad = str(b.get("id", ""))
            if not lad:
                continue
            holders[lad] = _pick_name(lad, str(b.get("name", lad)))
    return holders


# ── HARVEST CURVE per season ─────────────────────────────────────────────────
DEFAULT_HARVEST_PARAMS = [
    {"season": 0, "mean": 0.20, "std_dev": 0.05, "min_val": 0.10, "max_val": 0.40,
     "description": "Spring - planting, light cashflow"},
    {"season": 1, "mean": 0.30, "std_dev": 0.08, "min_val": 0.15, "max_val": 0.60,
     "description": "Summer - pasturage and wool"},
    {"season": 2, "mean": 1.50, "std_dev": 0.45, "min_val": 0.50, "max_val": 3.00,
     "description": "Autumn - main grain harvest"},
    {"season": 3, "mean": 0.10, "std_dev": 0.04, "min_val": 0.00, "max_val": 0.25,
     "description": "Winter - stored goods and fines"},
]

# ── FACTIONS — what each kingdom starts with ─────────────────────────────────
FACTION_SEED = [
    {"id": "england",  "name": "Kingdom of England",   "color_hex": "#c8102e", "treasury": 2500},
    {"id": "wales",    "name": "Principality of Wales","color_hex": "#00693e", "treasury": 600},
    {"id": "scotland", "name": "Kingdom of Scotland",  "color_hex": "#005eb8", "treasury": 900},
]

# ── BARONY OVERRIDES (per-LAD economy where we know the real figures) ───────
# Default behaviour is pro-rata: each barony in a county gets county_value/N.
# Where we have better-than-default data — major cities, ports, monastic
# holdings — we override here by LAD13CD. Add freely; rerun extract_design.py.
#
# Fields:
#   income, garrison, population — same semantics as county-level.
#   name (optional) — overrides LAD13NM for the in-game label.
BARONY_OVERRIDES = {
    # London — the City of London + Westminster wards, the wealthiest LADs.
    # E09000001 = City of London proper; bumping its slice well above pro-rata.
    "E09000001": {"name": "London", "income": 220, "garrison": 180, "population": 25000},
    # York (Yorkshire) — second city of England.
    "E06000014": {"name": "York", "income": 110, "garrison": 80, "population": 12000},
    # Bristol — major port.
    "E06000023": {"name": "Bristol", "income": 85, "garrison": 60, "population": 8000},
    # Norwich (Norfolk).
    "E07000148": {"name": "Norwich", "income": 90, "garrison": 70, "population": 10000},
    # Cardiff (Welsh march, Glamorgan).
    "W06000015": {"name": "Cardiff", "income": 50, "garrison": 70, "population": 4500},
    # Edinburgh (Lothian).
    "S12000036": {"name": "Edinburgh", "income": 80, "garrison": 90, "population": 8000},
}


# ── COUNTRY mapping (geographic, used for label tier + aggregation) ──────────
COUNTRY_BY_DUCHY = {
    "lancaster":  "England", "chester":    "England", "march":      "England",
    "gloucester": "England", "norfolk":    "England", "cornwall":   "England",
    "gwynedd":    "Wales",   "deheubarth": "Wales",   "morgannwg":  "Wales",
    "highlands":  "Scotland","moray":      "Scotland","lothian":    "Scotland",
}

# Faction ownership at game start. Morgannwg is geographically Welsh but
# politically held by Marcher lords loyal to England in the 1247 starting set.
FACTIONS_BY_DUCHY = {
    "lancaster":  "england", "chester":    "england", "march":      "england",
    "gloucester": "england", "norfolk":    "england", "cornwall":   "england",
    "gwynedd":    "wales",   "deheubarth": "wales",   "morgannwg":  "england",
    "highlands":  "scotland","moray":      "scotland","lothian":    "scotland",
    "wales":      "wales", "scotland": "scotland",   # v1 legacy
}


# ── PER-BARONY DISTRIBUTOR ──────────────────────────────────────────────────
# Given a county's baseline and the list of LAD codes that make up that
# county, hand each LAD a deterministic slice of the baseline. ±25%
# variation is derived from a hash of (LAD_code + field) so the same input
# always yields the same output — reruns of the script don't drift.

_VARIATION_PCT = 25     # ± percent

def _deterministic_variation(lad_code, field):
    """Stable, reproducible value in [-_VARIATION_PCT, +_VARIATION_PCT] / 100."""
    h = hashlib.md5((lad_code + ":" + field).encode("utf-8")).hexdigest()
    n = int(h[:8], 16)
    span = 2 * _VARIATION_PCT + 1
    return ((n % span) - _VARIATION_PCT) / 100.0


def distribute_baronies(geometry):
    """Build the {LAD13CD: {income, garrison, population, name?}} dict.

    For each county listed in COUNTY_BASELINE, partition its totals across
    the baronies the geometry pipeline produced (which are LAD13CD codes).
    BARONY_OVERRIDES win — those values stay exactly as written.

    Args:
      geometry (dict): parsed gb_godot.json (needs ['counties'][cn]['baronies']).
    Returns:
      dict[lad_code → dict] with income/garrison/population/(name?).
    """
    out = {}
    counties = geometry.get("counties", {})
    # First pass: apply explicit overrides verbatim.
    for lad, vals in BARONY_OVERRIDES.items():
        out[lad] = dict(vals)
    # Second pass: distribute baseline per county to the remaining LADs.
    for cn, county_data in counties.items():
        baronies = county_data.get("baronies", [])
        if not baronies:
            continue
        baseline = COUNTY_BASELINE.get(cn)
        if baseline is None:
            # County not in baseline table — fall back to a small placeholder
            # so DesignData still has SOMETHING to return.
            baseline = {"income": 50, "garrison": 50, "population": 5000}
        # Compute remaining-after-overrides budget so the county still hits
        # roughly the baseline. Sum what overrides took out.
        override_totals = {"income": 0, "garrison": 0, "population": 0}
        non_override = []
        for b in baronies:
            lad = b.get("id", "")
            if lad in BARONY_OVERRIDES:
                for k in override_totals:
                    override_totals[k] += int(BARONY_OVERRIDES[lad].get(k, 0))
            else:
                non_override.append(b)
        if not non_override:
            continue
        per_b = {
            k: max(1, (baseline[k] - override_totals[k]) // len(non_override))
            for k in ("income", "garrison", "population")
        }
        for b in non_override:
            lad = b.get("id", "")
            if not lad:
                continue
            entry = {}
            for k in ("income", "garrison", "population"):
                v = per_b[k] * (1.0 + _deterministic_variation(lad, k))
                # Floor at 1/100 for income/garrison; population can be small.
                floor = 1 if k != "population" else 50
                entry[k] = max(floor, int(v))
            out[lad] = entry
    return out


def main():
    # We need the geometry pipeline's output to know which LADs belong to
    # which county. If it's missing, ask the user to run convert first.
    if not os.path.exists(INPUT_GEOMETRY):
        raise SystemExit(
            "missing %s — run convert_to_godot.py first" % INPUT_GEOMETRY
        )
    with open(INPUT_GEOMETRY, "r", encoding="utf-8") as f:
        geometry = json.load(f)

    baronies = distribute_baronies(geometry)
    barony_holders = build_barony_holders(geometry)

    out = {
        "meta": {"version": 3, "notes": "Hand-edit freely; reload Godot to apply."},
        "monarchs":              MONARCHS,
        "barony_holders":        barony_holders,
        "duchies":               DUCHY_DESIGN,
        "counties":              COUNTY_DESIGN,
        # Source of truth for income/garrison/population (LAD13CD keys).
        # County / duchy / country totals are derived as sums at runtime.
        "baronies":              baronies,
        "fertility_by_duchy":    FERTILITY_BY_DUCHY,
        "default_harvest_params": DEFAULT_HARVEST_PARAMS,
        "faction_seed":          FACTION_SEED,
        "country_by_duchy":      COUNTRY_BY_DUCHY,
        "factions_by_duchy":     FACTIONS_BY_DUCHY,
    }
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    size = os.path.getsize(OUTPUT_PATH) / 1024.0
    print(f"Wrote {OUTPUT_PATH}: {len(COUNTY_DESIGN)} counties, {len(DUCHY_DESIGN)} duchies, "
          f"{len(baronies)} baronies ({len(BARONY_OVERRIDES)} overrides + "
          f"{len(baronies) - len(BARONY_OVERRIDES)} generated), {size:.1f} KB")


if __name__ == "__main__":
    main()
