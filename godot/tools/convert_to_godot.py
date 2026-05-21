"""
convert_to_godot.py
Converts data/gb-topo_lad.json → data/gb_godot.json
with polygons as flat [x,y] arrays ready for Godot PackedVector2Array.

Run from the godot/ project directory:
    python convert_to_godot.py

Borders are simplified at the ARC level (not per polygon) so shared edges
between neighbouring counties come out identical — no gaps or overlaps.
"""

import json
import math
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_PATH  = os.path.join(SCRIPT_DIR, "data", "gb-topo_lad.json")
OUTPUT_PATH = os.path.join(SCRIPT_DIR, "data", "gb_godot.json")

# ── LOAD TOPOJSON ──────────────────────────────────────────────────────────────
with open(INPUT_PATH, "r") as f:
    topo = json.load(f)

# ── DECODE ARCS (TopoJSON arc decoding) ────────────────────────────────────────
def decode_arcs(topo):
    """Decode delta-encoded TopoJSON arcs into absolute coordinates."""
    arcs = topo["arcs"]
    decoded = []
    for arc in arcs:
        coords = []
        x, y = 0, 0
        for dx, dy in arc:
            x += dx
            y += dy
            coords.append([x, y])
        decoded.append(coords)
    return decoded

def dequantize(coords, transform):
    """Apply TopoJSON quantization transform to get real lon/lat."""
    sx, sy = transform["scale"]
    tx, ty = transform["translate"]
    return [[c[0] * sx + tx, c[1] * sy + ty] for c in coords]

# Check if quantized
has_transform = "transform" in topo
if has_transform:
    transform = topo["transform"]
    raw_arcs = decode_arcs(topo)
    arcs = [dequantize(a, transform) for a in raw_arcs]
else:
    # Arcs are already in absolute coordinates
    arcs = topo["arcs"]

def resolve_arc(index):
    """Resolve a single arc index (negative = reversed)."""
    if index >= 0:
        return arcs[index]
    else:
        return list(reversed(arcs[~index]))

def resolve_ring(ring_indices):
    """Resolve a ring of arc indices into a coordinate list."""
    coords = []
    for idx in ring_indices:
        arc_coords = resolve_arc(idx)
        # Skip first point of subsequent arcs (it's the same as last point of previous)
        if coords:
            arc_coords = arc_coords[1:]
        coords.extend(arc_coords)
    return coords

def geometry_to_polygons(geom):
    """Extract all polygon rings from a TopoJSON geometry."""
    polygons = []
    if geom["type"] == "Polygon":
        for ring in geom["arcs"]:
            polygons.append(resolve_ring(ring))
    elif geom["type"] == "MultiPolygon":
        for polygon in geom["arcs"]:
            for ring in polygon:
                polygons.append(resolve_ring(ring))
    return polygons

# ── MERCATOR PROJECTION ────────────────────────────────────────────────────────
# Project lon/lat → Godot pixel coordinates. Bounds are taken over ALL relevant
# UK LADs (E/W/S) so Wales and Scotland fit on the canvas alongside England.

def mercator(lon, lat):
    """Simple Mercator projection."""
    x = math.radians(lon)
    y = math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
    return x, y

geoms = topo["objects"]["lad"]["geometries"]
uk_geoms = [g for g in geoms if g["properties"]["LAD13CD"][0] in ("E", "W", "S")]

# Pass 1: collect every lon/lat that will land on the canvas, for bounds.
all_lons, all_lats = [], []
for geom in uk_geoms:
    for poly in geometry_to_polygons(geom):
        for lon, lat in poly:
            all_lons.append(lon)
            all_lats.append(lat)

min_lon, max_lon = min(all_lons), max(all_lons)
min_lat, max_lat = min(all_lats), max(all_lats)
bx0, by0 = mercator(min_lon, min_lat)
bx1, by1 = mercator(max_lon, max_lat)

# Target canvas: 1000 wide, height proportional to the projected aspect ratio.
TARGET_W = 1000
aspect = (by1 - by0) / (bx1 - bx0)
TARGET_H = int(TARGET_W * aspect)
PADDING = 30

def project(lon, lat):
    """Project lon/lat → Godot coordinates (0..TARGET_W, Y-down)."""
    mx, my = mercator(lon, lat)
    x = PADDING + (mx - bx0) / (bx1 - bx0) * (TARGET_W - 2 * PADDING)
    y = PADDING + (1 - (my - by0) / (by1 - by0)) * (TARGET_H - 2 * PADDING)
    return round(x, 1), round(y, 1)


# ── ARC-LEVEL PROJECTION + SIMPLIFICATION ──────────────────────────────────────
# TopoJSON arcs are SHARED between neighbouring geometries. Projecting and
# simplifying each arc ONCE (instead of per-polygon, as the previous version
# did) guarantees that a boundary shared by two counties comes out as exactly
# the same point list on both sides — so there are no gaps or T-junctions.

SIMPLIFY_SQ_THRESHOLD = 4.0   # px² minimum spacing (= 2px). Lower keeps more detail,
                              # but Godot's Polygon2D triangulator chokes on dense
                              # near-collinear runs in complex coastlines (Argyll,
                              # Galloway, etc.) — 4.0 is the sweet spot between
                              # detail and reliable rendering.

def simplify_arc(coords):
    """Drop colinear-ish intermediate points, but always keep both endpoints."""
    if len(coords) <= 2:
        return coords
    out = [coords[0]]
    for pt in coords[1:-1]:
        dx = pt[0] - out[-1][0]
        dy = pt[1] - out[-1][1]
        if dx * dx + dy * dy > SIMPLIFY_SQ_THRESHOLD:
            out.append(pt)
    out.append(coords[-1])
    return out

# Project & simplify EACH ARC ONCE. After this, resolve_arc() returns the
# already-projected, already-simplified coord list.
arcs = [
    simplify_arc([list(project(lon, lat)) for lon, lat in arc])
    for arc in arcs
]

# ── LAD → HISTORIC COUNTY MAPPING ──────────────────────────────────────────────
LAD_TO_COUNTY = {}
LAD_TO_DUCHY = {}

def assign(codes, county, duchy):
    for c in codes:
        LAD_TO_COUNTY[c] = county
        LAD_TO_DUCHY[c] = duchy

# DUCHY OF LANCASTER
assign(['E06000057','E08000021','E08000022','E08000023'], 'Northumberland', 'lancaster')
assign(['E06000047','E06000001','E06000002','E06000003','E06000004','E06000005','E08000024'], 'Durham', 'lancaster')
assign(['E07000026','E07000028','E07000029'], 'Cumberland', 'lancaster')
assign(['E07000030','E07000031'], 'Westmorland', 'lancaster')
assign(['E06000008','E06000009','E07000117','E07000118','E07000119','E07000120','E07000121','E07000122','E07000123','E07000124','E07000125','E07000126','E07000127','E07000128','E08000001','E08000002','E08000003','E08000004','E08000005','E08000006','E08000007','E08000008','E08000009','E08000010','E08000011','E08000012','E08000013','E08000014','E08000015','E06000006','E06000007'], 'Lancashire', 'lancaster')
assign(['E06000010','E06000011','E06000014','E07000163','E07000164','E07000165','E07000166','E07000167','E07000168','E07000169','E08000016','E08000017','E08000018','E08000019','E08000032','E08000033','E08000034','E08000035','E08000036','E07000027'], 'Yorkshire', 'lancaster')

# EARLDOM OF CHESTER
assign(['E06000049','E06000050'], 'Cheshire', 'chester')
assign(['E06000015','E07000032','E07000033','E07000034','E07000035','E07000036','E07000037','E07000038','E07000039'], 'Derbyshire', 'chester')
assign(['E06000018','E07000170','E07000171','E07000172','E07000173','E07000174','E07000175','E07000176'], 'Nottinghamshire', 'chester')
assign(['E06000012','E06000013','E07000136','E07000137','E07000138','E07000139','E07000140','E07000141','E07000142'], 'Lincolnshire', 'chester')
assign(['E06000021','E07000192','E07000193','E07000194','E07000195','E07000196','E07000197','E07000198','E07000199'], 'Staffordshire', 'chester')
assign(['E06000016','E06000017','E07000129','E07000130','E07000131','E07000132','E07000133','E07000134','E07000135'], 'Leicestershire', 'chester')

# WELSH MARCHES
assign(['E06000051','E06000020'], 'Shropshire', 'march')
assign(['E06000019'], 'Herefordshire', 'march')

# DUCHY OF GLOUCESTER
assign(['E07000234','E07000235','E07000236','E07000237','E07000238','E07000239'], 'Worcestershire', 'gloucester')
assign(['E07000218','E07000219','E07000220','E07000221','E07000222','E08000025','E08000026','E08000027','E08000028','E08000029','E08000030','E08000031'], 'Warwickshire', 'gloucester')
assign(['E06000022','E06000023','E06000025','E07000078','E07000079','E07000080','E07000081','E07000082','E07000083'], 'Gloucestershire', 'gloucester')
assign(['E07000177','E07000178','E07000179','E07000180','E07000181'], 'Oxfordshire', 'gloucester')
assign(['E06000042','E07000004','E07000005','E07000006','E07000007'], 'Buckinghamshire', 'gloucester')
assign(['E07000150','E07000151','E07000152','E07000153','E07000154','E07000155','E07000156'], 'Northamptonshire', 'gloucester')
assign(['E06000032','E06000055','E06000056'], 'Bedfordshire', 'gloucester')

# EARLDOM OF NORFOLK
assign(['E07000143','E07000144','E07000145','E07000146','E07000147','E07000148','E07000149'], 'Norfolk', 'norfolk')
assign(['E07000200','E07000201','E07000202','E07000203','E07000204','E07000205','E07000206'], 'Suffolk', 'norfolk')
assign(['E06000033','E06000034','E07000066','E07000067','E07000068','E07000069','E07000070','E07000071','E07000072','E07000073','E07000074','E07000075','E07000076','E07000077'], 'Essex', 'norfolk')
assign(['E06000031','E07000008','E07000009','E07000010','E07000011','E07000012'], 'Cambridgeshire', 'norfolk')
assign(['E07000095','E07000096','E07000098','E07000099','E07000102','E07000103','E07000240','E07000241','E07000242','E07000243'], 'Hertfordshire', 'norfolk')
assign(['E09000001','E09000002','E09000003','E09000004','E09000005','E09000006','E09000007','E09000008','E09000009','E09000010','E09000011','E09000012','E09000013','E09000014','E09000015','E09000016','E09000017','E09000018','E09000019','E09000020','E09000021','E09000022','E09000023','E09000024','E09000025','E09000026','E09000027','E09000028','E09000029','E09000030','E09000031','E09000032','E09000033'], 'Middlesex', 'norfolk')
assign(['E06000035','E07000105','E07000106','E07000107','E07000108','E07000109','E07000110','E07000111','E07000112','E07000113','E07000114','E07000115','E07000116'], 'Kent', 'norfolk')
assign(['E07000207','E07000208','E07000209','E07000210','E07000211','E07000212','E07000213','E07000214','E07000215','E07000216','E07000217'], 'Surrey', 'norfolk')
assign(['E06000043','E07000061','E07000062','E07000063','E07000064','E07000065','E07000223','E07000224','E07000225','E07000226','E07000227','E07000228','E07000229'], 'Sussex', 'norfolk')
assign(['E06000036','E06000037','E06000038','E06000039','E06000040','E06000041'], 'Berkshire', 'norfolk')

# DUCHY OF CORNWALL
assign(['E06000044','E06000045','E06000046','E07000084','E07000085','E07000086','E07000087','E07000088','E07000089','E07000090','E07000091','E07000092','E07000093','E07000094'], 'Hampshire', 'cornwall')
assign(['E06000030','E06000054'], 'Wiltshire', 'cornwall')
assign(['E06000028','E06000029','E07000048','E07000049','E07000050','E07000051','E07000052','E07000053'], 'Dorset', 'cornwall')
assign(['E06000024','E07000187','E07000188','E07000189','E07000190','E07000191'], 'Somerset', 'cornwall')
assign(['E06000026','E06000027','E07000040','E07000041','E07000042','E07000043','E07000044','E07000045','E07000046','E07000047'], 'Devon', 'cornwall')
assign(['E06000052','E06000053'], 'Cornwall', 'cornwall')

# DUCHY OF GWYNEDD (Welsh-controlled north and east, Llywelyn's heartland)
assign(['W06000001','W06000002','W06000003'], 'Gwynedd', 'gwynedd')                       # Anglesey + Gwynedd + Conwy
assign(['W06000004','W06000005','W06000006'], 'Perfeddwlad', 'gwynedd')                   # Denbighshire + Flintshire + Wrexham
assign(['W06000023'], 'Powys', 'gwynedd')                                                  # Powys LAD

# DUCHY OF DEHEUBARTH (Welsh-controlled south-west)
assign(['W06000008'], 'Ceredigion', 'deheubarth')                                          # Ceredigion LAD
assign(['W06000009','W06000010'], 'Dyfed', 'deheubarth')                                   # Pembrokeshire + Carmarthenshire

# DUCHY OF MORGANNWG (Norman Marcher-controlled south coast and SE)
assign(['W06000011','W06000012','W06000013'], 'Gower', 'morgannwg')                        # Swansea + NPT + Bridgend
assign(['W06000014','W06000015','W06000016','W06000018','W06000024'], 'Glamorgan', 'morgannwg')  # Vale + Cardiff + RCT + Caerphilly + Merthyr
assign(['W06000019','W06000020','W06000021','W06000022'], 'Gwent', 'morgannwg')           # Blaenau Gwent + Torfaen + Monmouthshire + Newport

# DUCHY OF HIGHLANDS (Scottish north, west, islands)
assign(['S12000017'], 'Highland', 'highlands')                                             # Highland LAD
assign(['S12000035','S12000013'], 'Argyll', 'highlands')                                   # Argyll & Bute + Eilean Siar
assign(['S12000023','S12000027'], 'Orkney', 'highlands')                                   # Orkney + Shetland

# EARLDOM OF MORAY (Scottish east coast / Pictland)
assign(['S12000020','S12000033','S12000034','S12000041'], 'Moray', 'moray')                # Moray + Aberdeen City + Aberdeenshire + Angus
assign(['S12000024','S12000030','S12000005'], 'Strathearn', 'moray')                       # Perth+Kinross + Stirling + Clackmannanshire
assign(['S12000015','S12000042'], 'Fife', 'moray')                                         # Fife + Dundee City

# EARLDOM OF LOTHIAN (Scottish south, Anglo-Norman)
assign(['S12000019','S12000010','S12000040','S12000036','S12000014'], 'Lothian', 'lothian')  # Midlothian + East Lothian + West Lothian + Edinburgh + Falkirk
assign(['S12000026'], 'Borders', 'lothian')                                                  # Scottish Borders
assign(['S12000044','S12000029','S12000046','S12000038','S12000011','S12000039','S12000045','S12000018','S12000021','S12000028','S12000008'], 'Strathclyde', 'lothian')  # all Lanarkshires + Glasgow + Renfrewshires + Dunbartonshires + Inverclyde + Ayrshires
assign(['S12000006'], 'Galloway', 'lothian')                                                # Dumfries and Galloway

# ── DESIGN DATA HAS MOVED ────────────────────────────────────────────────────
# Lord names, baseline income, garrison size, population — all the
# hand-authored "game design" numbers — now live in data/gb_design.json,
# generated by extract_design.py. Run that script when you want to change
# values; this pipeline writes geometry-only output.
#
# (Kept the original COUNTY_DATA / DUCHY_DATA dicts below commented out for
# reference until the design file is verified working end-to-end. Strip
# when comfortable.)
# Design data (lord names, baseline income, garrison size, population,
# fertility, harvest curves) now lives in data/gb_design.json — see
# extract_design.py. This script emits geometry only.

# ── MERGE LADs INTO HISTORIC COUNTIES ──────────────────────────────────────────
# At this point each arc has ALREADY been projected and simplified once.
# geometry_to_polygons(geom) returns coord lists assembled from those shared
# arcs — so neighbouring counties end up with point-identical shared edges.
from collections import defaultdict
county_polys_raw = defaultdict(list)  # county_name → list of LAD-level polygon rings

for geom in geoms:
    code = geom["properties"]["LAD13CD"]
    county = LAD_TO_COUNTY.get(code)
    if not county:
        continue
    for ring in geometry_to_polygons(geom):
        if len(ring) >= 3:
            county_polys_raw[county].append([list(p) for p in ring])

# Use shapely to UNION all LAD polygons within each county. This eliminates
# internal LAD boundaries (Yorkshire was visibly showing them) and produces
# clean, topology-correct county shapes. unary_union is robust to:
#   - shared edges between adjacent LADs (welds them seamlessly)
#   - sub-pixel mismatches that Godot's Geometry2D.merge_polygons couldn't handle
#   - holes and disjoint pieces (returns MultiPolygon when a county has islands)
from shapely.geometry import Polygon as ShPoly, MultiPolygon, Point
from shapely.ops import unary_union
from shapely.validation import make_valid

def _shapely_to_rings(geom):
    """Flatten a shapely Polygon/MultiPolygon into a list of [[x,y],...] rings
    (outer shells only). Holes are dropped — they're features of the polygon's
    interior, not separate landmasses, and Godot's Polygon2D doesn't render them
    anyway in our setup.

    Coords are rounded to 2 decimal places (0.01 of a coordinate unit). 1dp
    was occasionally causing self-intersections after rounding (the
    Gloucestershire / Essex bug); 2dp keeps the data compact while leaving
    enough precision to preserve topology."""
    rings = []
    if geom.is_empty:
        return rings
    if geom.geom_type == "Polygon":
        polys = [geom]
    elif geom.geom_type == "MultiPolygon":
        polys = list(geom.geoms)
    else:
        return rings
    for p in polys:
        coords = list(p.exterior.coords)
        if len(coords) >= 2 and coords[0] == coords[-1]:
            coords = coords[:-1]
        if len(coords) < 3:
            continue
        rounded = [[round(x, 2), round(y, 2)] for x, y in coords]
        # Defensive: rebuild the polygon from rounded coords and run make_valid
        # if it still tripped a self-intersection. If make_valid produces a
        # MultiPolygon (rare), take the largest piece — outliers are usually
        # zero-area slivers that Godot wouldn't render anyway.
        try:
            check = ShPoly(rounded)
            if not check.is_valid:
                fixed = make_valid(check)
                if fixed.geom_type == "Polygon":
                    rc = list(fixed.exterior.coords)
                    if len(rc) >= 2 and rc[0] == rc[-1]:
                        rc = rc[:-1]
                    rounded = [[round(x, 2), round(y, 2)] for x, y in rc]
                elif fixed.geom_type == "MultiPolygon":
                    biggest = max(fixed.geoms, key=lambda g: g.area)
                    rc = list(biggest.exterior.coords)
                    if len(rc) >= 2 and rc[0] == rc[-1]:
                        rc = rc[:-1]
                    rounded = [[round(x, 2), round(y, 2)] for x, y in rc]
        except Exception:
            pass
        if len(rounded) >= 3:
            rings.append(rounded)
    return rings

county_polys = {}     # county_name → list of merged outer rings (one per landmass)
for cn, raw_rings in county_polys_raw.items():
    sh_polys = []
    for r in raw_rings:
        try:
            p = ShPoly(r)
            # buffer(0) is the canonical shapely trick to clean up self-intersecting
            # / invalid polygons. Necessary because a few LAD rings have minor
            # topology issues after arc projection.
            if not p.is_valid:
                p = p.buffer(0)
            if not p.is_empty and p.area > 0:
                sh_polys.append(p)
        except Exception:
            continue
    if not sh_polys:
        county_polys[cn] = []
        continue
    # unary_union typically returns a valid geometry, BUT subsequent rounding
    # of the exterior coords to 2dp can re-introduce self-intersections at
    # tight neck-points (Gloucestershire and Essex were both hitting this).
    # buffer(0) is shapely's canonical "scrub topology" trick — combined
    # with make_valid as a belt-and-braces fallback it produces output that
    # survives the round trip to the JSON.
    merged = unary_union(sh_polys).buffer(0)
    if not merged.is_valid:
        merged = make_valid(merged)
    county_polys[cn] = _shapely_to_rings(merged)


# ── DUCHY POLYGONS (union of constituent counties) ────────────────────────────
# This is what the renderer actually wants for the THICK duchy boundary lines.
# Without it, the previous code was forced to approximate duchy outlines as
# "the entire outline of any county that touches another duchy", which drew
# the thick treatment on a county's internal same-duchy edges too. By unioning
# the LAD-level polygons per duchy we get the TRUE perimeter, drawn exactly
# along duchy-to-duchy and duchy-to-sea boundaries.
duchy_polys = {}  # duchy_id → list of merged outer rings
# Build duchy → counties map by reverse-lookup through LAD_TO_DUCHY. This
# is the only place we still iterate "all known duchies" — derived from
# LAD assignments, not from DUCHY_DATA which has moved to gb_design.json.
_duchy_to_counties = defaultdict(list)
for code, dchy in LAD_TO_DUCHY.items():
    cn = LAD_TO_COUNTY.get(code)
    if cn and cn not in _duchy_to_counties[dchy]:
        _duchy_to_counties[dchy].append(cn)

for did in _duchy_to_counties.keys():
    duchy_sh_polys = []
    for cn in _duchy_to_counties.get(did, []):
        for ring in county_polys.get(cn, []):
            try:
                p = ShPoly(ring)
                if not p.is_valid:
                    p = p.buffer(0)
                if p.is_valid and not p.is_empty and p.area > 0:
                    duchy_sh_polys.append(p)
            except Exception:
                continue
    if not duchy_sh_polys:
        duchy_polys[did] = []
        continue
    merged_duchy = unary_union(duchy_sh_polys).buffer(0)
    if not merged_duchy.is_valid:
        merged_duchy = make_valid(merged_duchy)
    duchy_polys[did] = _shapely_to_rings(merged_duchy)


# ── BARONIES (per-LAD polygons under each county) ─────────────────────────────
# The county-level polygons are the unioned shape. To support the third
# political layer ("barony"), we re-walk the geom list and store EACH LAD
# as its own barony record, keeping the LAD13NM as the barony name. LADs
# are the smallest unit our source data ships at; further subdivision into
# fiefs/manors/castles will be point data (future work).
baronies_by_county = defaultdict(list)   # county_name → list of barony dicts
for geom in geoms:
    code = geom["properties"]["LAD13CD"]
    cn = LAD_TO_COUNTY.get(code)
    if not cn:
        continue
    raw_rings = []
    for ring in geometry_to_polygons(geom):
        if len(ring) >= 3:
            raw_rings.append([list(p) for p in ring])
    if not raw_rings:
        continue
    # Clean topology with shapely so the LAD's polygon is render-safe.
    sh_polys = []
    for r in raw_rings:
        try:
            p = ShPoly(r)
            if not p.is_valid:
                p = p.buffer(0)
            if p.is_valid and not p.is_empty and p.area > 0:
                sh_polys.append(p)
        except Exception:
            continue
    if not sh_polys:
        continue
    merged = unary_union(sh_polys).buffer(0)
    if not merged.is_valid:
        merged = make_valid(merged)
    rings = _shapely_to_rings(merged)
    if not rings:
        continue
    # Centroid for label placement.
    all_pts = [p for r in rings for p in r]
    if not all_pts:
        continue
    cx = round(sum(p[0] for p in all_pts) / len(all_pts), 2)
    cy = round(sum(p[1] for p in all_pts) / len(all_pts), 2)
    baronies_by_county[cn].append({
        "id":       code,
        "name":     geom["properties"].get("LAD13NM", code),
        "polygons": rings,
        "center":   [cx, cy],
    })

# ── COMPUTE CENTROIDS ──────────────────────────────────────────────────────────
def centroid(polygons):
    """Compute centroid from all polygon points."""
    xs, ys = [], []
    for poly in polygons:
        for x, y in poly:
            xs.append(x)
            ys.append(y)
    if not xs:
        return [0, 0]
    return [round(sum(xs)/len(xs), 1), round(sum(ys)/len(ys), 1)]

# ── COMPUTE ADJACENCY ──────────────────────────────────────────────────────────
# Two counties are adjacent if any of their LADs share an arc
lad_to_county_map = {}
for geom in geoms:
    code = geom["properties"]["LAD13CD"]
    cn = LAD_TO_COUNTY.get(code)
    if cn:
        lad_to_county_map[code] = cn

# Build arc-sharing adjacency from topology
arc_usage = defaultdict(set)  # arc_index → set of county names
for geom in geoms:
    code = geom["properties"]["LAD13CD"]
    cn = LAD_TO_COUNTY.get(code)
    if not cn:
        continue
    def collect_arcs(arcs_data):
        for item in arcs_data:
            if isinstance(item, list):
                collect_arcs(item)
            else:
                arc_usage[abs(item)].add(cn)
    collect_arcs(geom["arcs"])

adjacency = defaultdict(set)
for arc_idx, counties_using in arc_usage.items():
    counties_list = list(counties_using)
    for i in range(len(counties_list)):
        for j in range(i+1, len(counties_list)):
            if counties_list[i] != counties_list[j]:
                adjacency[counties_list[i]].add(counties_list[j])
                adjacency[counties_list[j]].add(counties_list[i])

# ── BUILD OUTPUT ───────────────────────────────────────────────────────────────
output = {
    "meta": {
        "name": "Kingdom of England, Wales & Scotland",
        "year": 1247,
        "engine": "Godot4",
        "coordinate_space": f"{TARGET_W}x{TARGET_H}",
        "notes": "Coordinates are projected Mercator, Y-down. Use as Polygon2D.polygon in Godot. Scale with world_scale as needed."
    },
    "duchies": {},
    "counties": {},
    "adjacency": {},
}

# Geometry-only output. Per the new split, all design data (lord names,
# economy, fertility, harvest curves) lives in data/gb_design.json — see
# extract_design.py. DesignData.gd merges it back over the MapData dicts at
# load time, so downstream callers don't have to know about the split.
DUCHY_IDS = sorted({d for d in LAD_TO_DUCHY.values()})
for dk in DUCHY_IDS:
    dk_counties = set()
    for code, duchy in LAD_TO_DUCHY.items():
        if duchy == dk:
            cn = LAD_TO_COUNTY.get(code)
            if cn and cn in county_polys:
                dk_counties.add(cn)
    output["duchies"][dk] = {
        "counties": sorted(dk_counties),
        "polygons": duchy_polys.get(dk, []),
        "center":   centroid(duchy_polys.get(dk, [])),
    }

for cn, polys in county_polys.items():
    duchy = None
    for code, c in LAD_TO_COUNTY.items():
        if c == cn:
            duchy = LAD_TO_DUCHY.get(code)
            break
    center = centroid(polys)
    output["counties"][cn] = {
        "duchy":    duchy or "unknown",
        "center":   {"x": center[0], "y": center[1]},
        "polygons": polys,
        # Third-tier subdivisions — one per source LAD.
        "baronies": baronies_by_county.get(cn, []),
    }
    output["adjacency"][cn] = sorted(adjacency.get(cn, set()))

# ── WRITE ──────────────────────────────────────────────────────────────────────
with open(OUTPUT_PATH, "w") as f:
    json.dump(output, f, separators=(',', ':'))

# Stats
total_pts = sum(sum(len(p) for p in polys) for polys in county_polys.values())
print(f"Output: {OUTPUT_PATH}")
print(f"Counties: {len(output['counties'])}")
print(f"Duchies: {len(output['duchies'])}")
print(f"Total polygon points: {total_pts}")
print(f"Coordinate space: {TARGET_W}x{TARGET_H}")
print(f"Adjacency pairs: {sum(len(v) for v in adjacency.values())//2}")
print(f"File size: {os.path.getsize(OUTPUT_PATH)/1024:.0f} KB")