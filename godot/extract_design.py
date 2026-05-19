"""
extract_design.py
One-time-ish script that writes data/gb_design.json containing all the
hand-authored "game design" data — anything that's NOT raw geometry. After
this, convert_to_godot.py is geometry-only and gb_design.json is the source
of truth for lord names, baseline economy, fertility, harvest curves, etc.

The data here used to live in two places:
  - COUNTY_DATA + DUCHY_DATA dicts inside convert_to_godot.py
  - FERTILITY_BY_DUCHY + DEFAULT_HARVEST_PARAMS in GameState.gd

Both moved here so a designer can rebalance income / fertility / climate
without re-running the polygon pipeline.

Run from godot/:
    python extract_design.py
"""

import json
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
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

# ── COUNTIES — earl, baseline economy ────────────────────────────────────────
COUNTY_DESIGN = {
    'Northumberland': {'earl':'Henry de Percy','income':240,'garrison':280,'population':42000},
    'Durham':         {'earl':'Prince-Bishop','income':310,'garrison':220,'population':38000},
    'Cumberland':     {'earl':'Ranulf de Dacre','income':195,'garrison':180,'population':31000},
    'Westmorland':    {'earl':'Robert de Clifford','income':160,'garrison':140,'population':22000},
    'Lancashire':     {'earl':'Thomas de Lancaster','income':285,'garrison':240,'population':55000},
    'Yorkshire':      {'earl':'Robert de Percy','income':420,'garrison':350,'population':82000},
    'Cheshire':       {'earl':'John de Lacy','income':220,'garrison':200,'population':48000},
    'Derbyshire':     {'earl':'Wm. de Ferrers','income':195,'garrison':170,'population':44000},
    'Nottinghamshire':{'earl':'Roger de Mortimer','income':210,'garrison':180,'population':46000},
    'Lincolnshire':   {'earl':'Ranulf de Blondeville','income':310,'garrison':260,'population':68000},
    'Staffordshire':  {'earl':'Robert de Stafford','income':185,'garrison':155,'population':40000},
    'Leicestershire': {'earl':'Simon de Montfort','income':240,'garrison':195,'population':52000},
    'Shropshire':     {'earl':'FitzAlan','income':165,'garrison':185,'population':35000},
    'Herefordshire':  {'earl':'Humphrey de Bohun','income':155,'garrison':170,'population':30000},
    'Worcestershire': {'earl':'Wm. de Beauchamp','income':195,'garrison':155,'population':42000},
    'Warwickshire':   {'earl':'Henry de Hastings','income':225,'garrison':180,'population':50000},
    'Gloucestershire':{'earl':'Richard de Clare','income':280,'garrison':220,'population':58000},
    'Oxfordshire':    {'earl':'Roger de Vere','income':260,'garrison':195,'population':54000},
    'Buckinghamshire':{'earl':'Walter Giffard','income':205,'garrison':165,'population':44000},
    'Northamptonshire':{'earl':'Saher de Quincy','income':215,'garrison':175,'population':48000},
    'Bedfordshire':   {'earl':'Roger de Beauchamp','income':170,'garrison':140,'population':35000},
    'Norfolk':        {'earl':'Roger Bigod','income':340,'garrison':270,'population':72000},
    'Suffolk':        {'earl':'Hugh Bigod','income':295,'garrison':235,'population':62000},
    'Essex':          {'earl':'Geoff. de Mandeville','income':310,'garrison':240,'population':66000},
    'Cambridgeshire': {'earl':'John de Burgh','income':235,'garrison':185,'population':50000},
    'Hertfordshire':  {'earl':'Roger de Tony','income':200,'garrison':155,'population':42000},
    'Middlesex':      {'earl':'Crown Direct (London)','income':480,'garrison':380,'population':95000},
    'Kent':           {'earl':'Hubert de Burgh','income':360,'garrison':290,'population':74000},
    'Surrey':         {'earl':'John de Warenne','income':245,'garrison':185,'population':50000},
    'Sussex':         {'earl':'John de Braose','income':225,'garrison':185,'population':48000},
    'Berkshire':      {'earl':'Crown Direct','income':200,'garrison':150,'population':38000},
    'Hampshire':      {'earl':'Baldwin de Reviers','income':265,'garrison':205,'population':56000},
    'Wiltshire':      {'earl':'Patrick de Chaworth','income':205,'garrison':165,'population':44000},
    'Dorset':         {'earl':'Wm. de Mandeville','income':180,'garrison':145,'population':36000},
    'Somerset':       {'earl':'Roger de Clifford','income':220,'garrison':175,'population':46000},
    'Devon':          {'earl':'Hugh de Courtenay','income':195,'garrison':160,'population':40000},
    'Cornwall':       {'earl':'Richard of Cornwall','income':285,'garrison':210,'population':52000},
    # WELSH counties
    'Gwynedd':        {'earl':'Llywelyn ap Gruffudd','income':95,'garrison':220,'population':22000},
    'Perfeddwlad':    {'earl':'Dafydd ap Gruffudd','income':70,'garrison':140,'population':18000},
    'Powys':          {'earl':'Gruffudd Maelor','income':65,'garrison':120,'population':15000},
    'Ceredigion':     {'earl':'Maredudd ap Owain','income':55,'garrison':95,'population':11000},
    'Dyfed':          {'earl':'Rhys ap Maredudd','income':75,'garrison':120,'population':16000},
    'Gower':          {'earl':'John de Mowbray','income':95,'garrison':150,'population':17000},
    'Glamorgan':      {'earl':'Richard de Clare','income':155,'garrison':210,'population':26000},
    'Gwent':          {'earl':'Humphrey de Bohun','income':110,'garrison':170,'population':19000},
    # SCOTTISH counties
    'Highland':       {'earl':'William, Earl of Ross','income':85,'garrison':220,'population':24000},
    'Argyll':         {'earl':'Eóghan of Lorn','income':95,'garrison':190,'population':19000},
    'Orkney':         {'earl':'Magnus, Jarl of Orkney','income':55,'garrison':90,'population':9000},
    'Moray':          {'earl':'Alexander Comyn','income':140,'garrison':190,'population':30000},
    'Strathearn':     {'earl':'Malise II of Strathearn','income':145,'garrison':180,'population':32000},
    'Fife':           {'earl':'Malcolm, Earl of Fife','income':160,'garrison':180,'population':36000},
    'Lothian':        {'earl':'Crown Direct (Alexander II)','income':215,'garrison':250,'population':46000},
    'Borders':        {'earl':'Walter Comyn','income':115,'garrison':190,'population':25000},
    'Strathclyde':    {'earl':'Maldouen, Earl of Lennox','income':185,'garrison':210,'population':40000},
    'Galloway':       {'earl':'Dervorguilla of Galloway','income':125,'garrison':175,'population':27000},
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
    'lothian':    1.05, 'galloway':   0.82,
    # Legacy fallbacks
    'wales':      0.85, 'scotland':   0.70,
}

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


def main():
    out = {
        "meta": {"version": 1, "notes": "Hand-edit freely; reload Godot to apply."},
        "duchies":               DUCHY_DESIGN,
        "counties":              COUNTY_DESIGN,
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
    print(f"Wrote {OUTPUT_PATH}: {len(COUNTY_DESIGN)} counties, {len(DUCHY_DESIGN)} duchies, {size:.1f} KB")


if __name__ == "__main__":
    main()
