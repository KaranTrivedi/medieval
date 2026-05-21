# Medieval Kingdom — Project Design Document
## A 13th Century Political Strategy Game

**Version:** 0.1 (Pre-Production)
**Engine:** Godot 4.x (Campaign) / Unreal Engine 5 (Battles — Phase 3)
**Setting:** England, Wales, Scotland — Anno Domini 1200–1300
**Genre:** Grand Strategy / Political Simulation

---

## Table of Contents

1. [Vision & Pillars](#vision)
2. [Engine & Technology](#engine)
3. [Social Hierarchy & Classes](#hierarchy)
4. [Political Titles & Appointments](#titles)
5. [Character Actions by Tier](#actions)
6. [The Gaussian Design Philosophy](#gaussian)
7. [The Feudal Node Graph](#graph)
8. [Campaign Map](#map)
9. [Geographic & Political Regions](#regions)
10. [Economy System](#economy)
11. [Church & Faith System](#church)
12. [Family, Dynasty & Bastard System](#dynasty)
13. [The Living Chronicle](#chronicle)
14. [Intrigue & Fog of Knowledge](#intrigue)
15. [AI Personality System](#ai)
16. [Battle System](#battles)
17. [Siege & Castle System](#sieges)
18. [Development Phases](#phases)
19. [File Structure](#files)

---

## 1. Vision & Pillars {#vision}

A medieval political simulation where the player governs as a monarch or noble, navigating a living web of feudal relationships, dynastic intrigue, economic management, and military conflict across 13th century Britain.

**Core Pillars:**

**Emergent Political Drama** — No scripted story. Every rebellion, betrayal, and alliance emerges from the simulation. The game generates its own Game of Thrones through the interaction of systems.

**The Gaussian Kingdom** — Every major system operates on a normal distribution. The player's job is not to maximise a single metric but to keep multiple systems near their optimal centre simultaneously. Too much royal power triggers baronial rebellion. Too little triggers fragmentation. The tension between these poles is the game.

**Knowledge as Power** — The player does not have omniscient vision of the political landscape. Intelligence is earned through espionage, diplomacy, and economic presence. A half-known family tree with redacted entries creates more strategic tension than any combat system.

**Living History** — The game writes its own chronicle. Every character, battle, alliance, and betrayal is recorded. A Bard (LLM) can narrate any character's arc. A Scribe records every deed. The player reads their own history as they make it.

---

## 2. Engine & Technology {#engine}

### Primary Engine: Godot 4

Godot 4 is the correct engine for this project for the following reasons:

- **2D first-class** — the campaign map, region polygons, UI panels, and overlay system are trivial compared to fighting UE5's 2D overhead
- **Node architecture mirrors feudal hierarchy** — a County node contains Barony child nodes which contain Fief children. The scene tree IS the political map
- **GDScript maps directly to designed systems** — graph traversal, Gaussian sampling, turn logic, and Voronoi data all integrate cleanly
- **No royalties** until significant revenue
- **Export to web** for rapid iteration

### Renderer Configuration

Use the **Compatibility renderer (OpenGL 3.3)** for the campaign layer. Do not use Forward+ (D3D12) for 2D. Set in `project.godot`:

```ini
[rendering]
renderer/rendering_method="gl_compatibility"
```

### Phase 3 Addition: Unreal Engine 5

Real-time battles will use UE5 with the Mass Entity system for large-scale unit simulation. The campaign and battle layers are separate applications that pass state via JSON.

### Geographic Data

- Source: ONS Local Authority Districts (LAD) TopoJSON — `gb-topo_lad.json`
- Coverage: England (326 LADs), Wales (22 LADs), Scotland (32 LADs)
- Projection: Mercator, normalised to 1000×1205 coordinate space
- Processed via Python into `england_godot.json` containing 39 historic counties, 8 political regions, polygon data, adjacency graph, economy stats

### Key Data Files

| File | Purpose |
|---|---|
| `gb-topo_lad.json` | Raw ONS boundary data |
| `england_godot.json` | Processed Godot-ready county polygons + political data |
| `MapData.gd` | Godot autoload singleton — map queries, pathfinding, polygon builder |
| `convert_to_godot.py` | Python pipeline from TopoJSON → Godot JSON |

---

## 3. Social Hierarchy & Classes {#hierarchy}

The game operates with four playable tiers plus one aggregate class.

### Tier 0 — Monarch
**King / Queen / Emperor / Regent**

The supreme ruler. Theoretically supreme lord over all. In the 1200s, many kings had to manage powerful, semi-independent nobles. The player starts here.

### Tier 1 — High Nobility
**Duke / Duchess / Earl / Count / Countess / Marquess / Margrave**

The highest-ranking vassals. Control large territories (duchies, counties). Owe direct allegiance to the king but operate with significant independence. The primary antagonists and allies.

### Tier 2 — Lesser Nobility
**Baron / Baroness / Lord / Viscount / Castellan**

Hold smaller manors or baronies. Act as local lords. Provide knights to higher nobles or the king. The middle layer — enough power to destabilise, not enough to rule alone.

### Tier 3 — Knights
**Chevalier / Knight Bachelor / Knight Banneret / Castellan-Knight / Hedge Knight**

Specialised armoured cavalry holding smaller fiefs in exchange for military service. The professional military elite. Their loyalty decides who wins civil wars. Hedge Knights hold no land — they appear at tournaments seeking patronage.

### Non-Playable Aggregate — Peasantry
**Serfs / Free Peasants / Villeins**

Approximately 90% of the population. **Not individual characters.** Represented as population numbers per region. Their aggregate behaviour drives the economy system, spawning merchants, guilds, and church income at threshold levels.

---

## 4. Political Titles & Appointments {#titles}

Titles are not fixed — they are granted, revoked, contested, and inherited. Each title carries land, income, military obligations, and political weight.

### Title Hierarchy

| Title | Tier | Notes |
|---|---|---|
| Emperor | 0 | Holy Roman Empire only. Seen as "first among equals" over kings |
| King / Queen | 0 | Supreme ruler of a kingdom |
| Duke / Duchess | 1 | Ruler of a duchy. Often a royal relative |
| Earl / Count / Countess | 1 | Ruler of a county or shire. Justice and governance |
| Marquess / Margrave | 1 | Ruler of a strategic border march |
| Viscount / Vicomte | 2 | Deputy acting on behalf of a Count |
| Baron / Baroness | 2 | Foundational landed nobility. Controls a manor |
| Castellan | 2–3 | Governor of a castle. May answer directly to the king |
| Knight / Chevalier | 3 | Holds a fief in exchange for military service |
| Hedge Knight | 3 | No land. Seeks patronage at tournaments |
| Bailiff / Reeve | — | Non-noble officer. Manages manor daily affairs |

### Appointment Mechanics

- **Licence to Crenellate** — Royal document required to build battlements. Building without one is effectively a declaration of rebellion
- **Great Offices of State** — Lord High Steward, Lord High Constable, Lord Chancellor, Lord Treasurer, Earl Marshal. Appointed by the monarch. Each grants economic or military bonuses per turn
- **Castellanships** — Royal castles (Windsor, Dover, Tower of London, Oxford) appointed by the king. Elevates knights to greater security and influence
- **Scutage** — Money paid instead of knight service. Legally permitted but politically telling

---

## 5. Character Actions by Tier {#actions}

Higher tiers have more actions with more impactful outcomes. Lower tiers have fewer, more local actions.

### Tier 0 — Monarch

*Political:* Call Great Council · Issue Royal Edict · Grant or Revoke Duchy · Appoint Great Officers of State · Grant Magna Carta concession · Legitimise Bastard · Declare Interregnum

*Military:* Raise Royal Host · Declare War · Sign Peace Treaty · Grant Safe Conduct · Commission Royal Castle · Call Crusade · Grant or Revoke Licence to Crenellate

*Economic:* Impose Tallage · Grant Market Charter · Seize Escheated Lands · Open Royal Mint · Grant Staple Rights · Commission Royal Castle

*Intrigue:* Issue Writ of Arrest on any lord · Commission Royal Spy Network · Forge Diplomatic Documents · Arrange Assassination

*Dynastic:* Arrange Royal Marriage · Grant Wardship · Demand Hostage · Crown Prince Declaration

### Tier 1 — High Nobility

*Political:* Petition Liege · Form Baronial League · Vote in Great Council · Withhold Homage · Appoint own Sheriff · Grant County to vassal · Hold County Court

*Military:* Raise County Levy · Lead Army · Besiege Castle · Conduct Chevauchée · Hire Mercenaries · Challenge peer to Trial by Combat

*Economic:* Collect Scutage · Grant Market Charter · Build or Upgrade Castle · Commission Road or Bridge · Tax Trade · Develop Port

*Intrigue:* Place Agent in peer's court · Bribe Sheriff · Fabricate Claim · Spread Rumour · Turn another lord's vassal

*Dynastic:* Arrange Marriage · Betroth heir to royalty · Legitimise bastard with bishop · Seek wardship of orphaned heir

### Tier 2 — Lesser Nobility

*Political:* Petition Overlord · Attend Court · Refuse Knight Service (pay scutage) · Form local alliance · Complain to King over Overlord's head (dangerous)

*Military:* Provide Knight Service (40 days) · Garrison own castle · Lead retinue · Defend border holding · Commission palisade or tower · Hire local mercenaries

*Economic:* Collect Manor Rents · Hold Manor Court · Grant or Revoke Mill rights · Impose Toll · Sell Surplus Grain · Develop Farmland · Appoint Reeve or Bailiff

*Intrigue:* Bribe local official · Spy on neighbour · Hide fugitive for fee · Forge local document

### Tier 3 — Knights

*Military:* Perform Knight Service · Joust in Tournament · Lead Cavalry Charge · Scout Enemy Territory · Guard Castle · Escort Noble or Merchant · Take Crusade Vow · Train Squire

*Political:* Petition Lord for better fief · Seek patronage from higher lord · Swear fealty to new lord · Support lord in dispute

*Economic:* Collect fief rents · Sell horses or equipment · Take prisoner for ransom · Trade military service for land

**Hedge Knight only:** Enter Tournament (prize = gold + patronage) · Seek mercenary employment · Challenge established knight for honour

---

## 6. The Gaussian Design Philosophy {#gaussian}

Every major system is modelled as a normal distribution. The player's goal is not to maximise any single metric but to keep multiple systems near their optimal centre simultaneously.

```
Each system has:
  Mean     = the stable, optimal state
  StdDev   = how volatile the system is
  Current  = where it sits right now

The "fun zone" is near the mean.
Deviation in either direction causes problems.
Extreme deviation causes catastrophe.
```

### Core Gaussian Systems

**Feudal Balance (Crown ↔ Barons)**
- Left tail (too much royal power): Lords have nothing to lose → mass rebellion
- Right tail (too much baronial power): Kingdom fragments, cannot field unified army
- Optimal: Lords feel respected, king maintains enforcement

**Piety (Secular ↔ Theocratic)**
- Left tail: Pope excommunicates, crusading orders leave, peasant unrest
- Right tail: Church owns too much land, bishops outrank lords, economy suffers
- Optimal: Church funded and respected, not controlling

**Harvest (Famine ↔ Surplus)**
- Gaussian in time — each year rolls on a distribution around base fertility
- Modifiers: armies marching through, disease, investment, good governance

**Dynastic Health (Extinction ↔ Overpopulation)**
- Too few heirs: Succession crisis, foreign intervention
- Too many heirs: Younger sons have nothing → become problems → Crusades export surplus
- Optimal: 2–3 healthy legitimate heirs

**Kingdom Stability**
- Computed as weighted average of all baronial satisfaction scores
- Below 18: Civil war trigger
- Below 35: Active challenge events possible
- Above 70: Realm prospers, barons attend court faithfully

### AI Gaussian Decision Making

Rather than deterministic thresholds, AI uses Gaussian sampling:

```gdscript
# Instead of: attack if strength_ratio > 1.0 (boring, predictable)
# Use: attack if strength_ratio > sample from N(0.6, 0.15)
# This means:
#   Sometimes attacks at 0.8 ratio (bold)
#   Sometimes waits until 1.2 ratio (cautious)
#   Feels like a human making judgment calls
```

---

## 7. The Feudal Node Graph {#graph}

The political world is modelled as a weighted directed graph. Every lord is a node. Every relationship is a weighted edge.

### Graph Properties

**Layers:** Four tiers of nodes. Each node can only directly interact with adjacent tiers, except the king who can reach any node.

**Influence Diameter:** Each node has an influence score. When a child node's influence exceeds its parent's, conflict triggers.

**Relationship Values:** -100 (bitter enemies) to +100 (sworn allies). Edges are updated by actions, events, marriages, insults, gifts, and time.

**Graph Theory Concepts in Use:**

- **Centrality** — The most connected lord is the Kingmaker. Control him and you influence half the network
- **Betweenness** — The broker lord sits between the most pairs. Cut him off and the network fractures
- **Clustering** — The algorithm detects blocs of high-positive-edge lords who vote, rebel, and support each other together
- **Shortest Path (BFS/Dijkstra)** — AI uses graph traversal to find the shortest political route to its goal

### The Displacement Mechanic

When any child node's influence exceeds its parent's, a conflict event triggers. Resolution is Gaussian — martial skill matters but doesn't guarantee outcome. This means:

- Strong but unlucky challengers can fall
- Weak but fortunate defenders can hold
- Historical upsets (Agincourt, Crécy) are mechanically possible

### The Blackfyre Scenario

Bastards accumulate influence and ambition independently. If a bastard's influence approaches their half-sibling's and they have a patron, they can assert a claim. This triggers a cascade:

1. **Dormant** — Claim exists, no one acts
2. **Whispers** — Rumours spread at court
3. **Manifesto** — Claim publicly declared
4. **Uprising** — Armed faction forms
5. **Civil War** — Full faction conflict
6. **Resolution** — One line displaces the other, or is crushed

Exiled claimants can be sheltered by foreign courts and used as diplomatic weapons indefinitely.

---

## 8. Campaign Map {#map}

### Architecture

```
Node2D (CampaignMap)
├── Camera2D
├── CountyLayer (Node2D)    ← Polygon2D nodes per county
├── BorderLayer (Node2D)    ← County and duchy outlines
├── LabelLayer (Node2D)     ← Text labels
├── EconomyLayer (Node2D)   ← Merchant/guild/tithe overlays
├── ChurchLayer (Node2D)    ← Cathedral and monastery markers
└── UI (CanvasLayer)
    ├── TopBar
    ├── InfoPanel
    ├── AdvisorPanel
    └── FamilyTreePanel
```

### Overlay System

Six map overlays, switchable at any time:

| Overlay | Shows |
|---|---|
| Political | Region colours by controlling faction |
| Income | Tax income heatmap per region |
| Loyalty | Baronial satisfaction coloured red–green |
| Military | All armies, garrison strength |
| Family | Which noble family controls each region |
| Church | Cathedral, monastery, tithe values |

### The Fog of Knowledge

The player does not start with full map visibility. Political information is earned:

- **Unknown** — Region exists but nothing is known
- **Rumoured** — Vague information from merchants or travellers
- **Known** — Basic facts: who controls it, rough income
- **Detailed** — Full profile including army strength and intentions
- **Intimate** — Secrets, hidden bastards, private schemes

Revelation methods: espionage, trade presence, diplomatic attendance, marriage alliances.

---

## 9. Geographic & Political Regions {#regions}

### England — Six Duchies, 37 Historic Counties

counties are a subset of duchies. The hierarchy:

faction (player-level)        england / wales / scotland
   └── duchy (political)      lancaster / gwynedd / lothian / …
         └── county (geo)     Yorkshire / Glamorgan / Fife / …
               └── LAD        E08000016 / W06000015 / S12000036 / …
                     └── polygon rings (Polygon2D vertices)

**Duchy of Lancaster** — Northumberland, Durham, Cumberland, Westmorland, Lancashire, Yorkshire

**Earldom of Chester** — Cheshire, Derbyshire, Nottinghamshire, Lincolnshire, Staffordshire, Leicestershire

**Welsh Marches** — Shropshire, Herefordshire

**Duchy of Gloucester** — Worcestershire, Warwickshire, Gloucestershire, Oxfordshire, Buckinghamshire, Northamptonshire, Bedfordshire

**Earldom of Norfolk** — Norfolk, Suffolk, Essex, Cambridgeshire, Hertfordshire, Middlesex, Kent, Surrey, Sussex, Berkshire

**Duchy of Cornwall** — Hampshire, Wiltshire, Dorset, Somerset, Devon, Cornwall

### Wales & Scotland

Both present in the data but initially governed by non-English rulers. Available as expansion targets or alliance partners.

### Fief & Barony Types

| Category | Types |
|---|---|
| Productive | Grain Manor, Wool Manor, Mill Manor, Vineyard, Salt Works, Iron Mine, Quarry, Forest Hold, Fishing Port |
| Military | Border Post, River Crossing, Mountain Pass, Harbour Fort, Road Station |
| Administrative | Market Town, Priory Fief, Sheriff's Manor, Hundred Court |
| Barony types | Agricultural, March, Forest, River, Mining, Coastal, Church |

---

## 10. Economy System {#economy}

### Peasant Aggregate Model

Peasants are **not individual characters**. They are population numbers per region. Their aggregate behaviour drives economic emergence.

Need to add a burghers subset to the peasant population. As cities develop, they can create an upper class of peasants. this type of population will produce its own unit types, and allow for creating more advanced resources in cities. Over production of burghers will cause issues with pop order dissatisfaction, reduction of percentage of peasants reduces raw inputs to the city. This can play into the gaussian system. Maintain balance of peasant types.

```
Population threshold → Merchants spawn
Merchants threshold  → Guild spawns
Guild income feeds   → Church tithe
Church tithe         → Cathedral or Monastery spawns
Cathedral            → Bishop NPC character created
Guild Master         → Guild Master NPC character created
```

### Income Sources (13th Century Accurate)

| Source | % of typical income |
|---|---|
| Agricultural Surplus (demesne farming) | 60% |
| Rents and Dues (mill toll, oven toll, bridge toll) | 20% |
| Justice Fines (lord's court) | 10% |
| Trade | 10% |

### The Wool-Cloth Dynamic

England produces the best raw wool. Flanders processes it into finished cloth and sells it back at triple the price. Controlling Calais controls the wool staple — a massive strategic asset. Whoever controls Flanders controls the most profitable trade route in Northern Europe.

### Three-Field Agricultural System

Each region's farmland rotates three ways annually. Each year's harvest rolls on a Gaussian distribution:

- Mean: 3× seed planted (historically accurate)
- StdDev: 1.2×
- Min: 0.5× (disaster — people starve)
- Max: 6× (exceptional bumper crop)

Modifiers: granary built (+0.5), lord present (+0.3), army marched through (−1.0), disease in livestock (−0.8), scorched earth (−1.5)

---

## 11. Church & Faith System {#church}

### Piety Gaussian

The Church is modelled on the Piety Gaussian system. Too secular → papal interdict and baronial exploitation of religious grievances. Too pious → Church owns untaxable land, bishops outrank lords politically.

### Church Economic Power

- Owns 25–30% of all land in 13th century England
- Tithe: 10% of all produce goes to Church
- Does not pay feudal dues to lords
- Templar banking: letters of credit (proto-banking system)

### Church Spawn Thresholds

| Institution | Population | Tithe |
|---|---|---|
| Village church | Any | Any |
| Monastery | ≥ 22,000 | ≥ 14 ₪/yr |
| Cathedral | ≥ 45,000 | ≥ 28 ₪/yr |

### The Crusade as Release Valve

The Crusade solves the Gaussian dynastic overpopulation problem by exporting surplus younger sons. It also provides:

- Piety bonus (+15 immediately)
- Knights volunteer (reduces military surplus)
- Younger sons leave (reduces dynastic tension)
- Cost: key lords absent for 8–12 turns, economy -15% for duration

---

## 12. Family, Dynasty & Bastard System {#dynasty}

### Noble Attributes

Every noble character has:

- **Martial** (1–10) — Battle effectiveness, challenge resolution
- **Diplomacy** (1–10) — Negotiation, alliance formation
- **Stewardship** (1–10) — Economic management, tax efficiency
- **Intrigue** (1–10) — Spy operations, scheme success
- **Piety** (1–10) — Church relations, Crusade effectiveness
- **Health** — Gaussian, determines lifespan
- **Traits** — Brave, Ambitious, Cruel, Pious, Paranoid etc. Some heritable

### Gaussian Inheritance

Children's stats are sampled from a normal distribution centred on the average of both parents:

```gdscript
func sample_child_stat(father_stat: int, mother_stat: int) -> int:
    var mean = (father_stat + mother_stat) / 2.0
    var std_dev = 2.0  # Genetic variance
    return clampi(int(gaussian(mean, std_dev)), 1, 10)

# 3% chance of exceptional talent: +3 to any one stat
# Models rare military genius or master diplomat
```

### The Bastard Lifecycle

**Stage 1 — Birth:** The game secretly tracks all affairs. The player receives a hidden event. Options: Acknowledge (public +Prestige, -Legitimacy), Deny, Send money secretly, or arrange disappearance (high Infamy if discovered).

**Stage 2 — Growing Up:** Acknowledged bastards grow up at court. Hidden bastards may be discovered through intrigue rolls.

**Stage 3 — The Blackfyre Moment:** Triggers when legitimate heir is weak, bastard has high Martial (7+), and a powerful patron backs the claim. A public declaration shifts the game into rebellion mechanics.

**Stage 4 — Civil War:** The faction splits. Lords choose sides. Knights' loyalty (determined by their individual relationship values) decides army composition. Knights are the deciding factor — their aggregate retinue sizes tip the balance.

**Stage 5 — Resolution:** Winner takes power. Loser is executed, imprisoned, or exiled. Exiled claimants become permanent diplomatic weapons for foreign powers.

### The Hidden Bastard

The most dramatic scenario: the king himself may secretly be illegitimate. Discovery has a small probability per turn. Full discovery triggers a kingdom-wide succession crisis that every faction can exploit.

---

## 13. The Living Chronicle {#chronicle}

### The Scribe

Every event in the campaign generates a structured historical record. The chronicle is not written by the player — it writes itself. The player reads it like they are discovering history.

Each entry contains:
- **Date** — Season and year
- **Type** — MILITARY, DIPLOMATIC, ECONOMIC, INTRIGUE, PERSONAL, CONFLICT, ROYAL_DECREE, CIVIL_WAR, PETITION
- **Text** — Period-appropriate prose
- **Visibility** — What the player can see depends on their intelligence level

### The Bard (LLM Integration)

When the player selects any character and clicks the Bard button, the game sends that character's chronicle entries to the Anthropic API. The model returns a 2–3 paragraph medieval-voiced narrative of that character's story arc. This is the "Campaign Wiki Bard" mechanic — human-readable narrative summaries of machine-generated history.

```
API call: claude-sonnet-4-20250514
Context: Character name, title, all chronicle entries
Output: ~180 words, past tense, medieval chronicler voice
```

### Character Relations History

Selecting two characters simultaneously (Shift+click) opens a comparison view:
- Left panel: Character A's recent chronicle (events mentioning B highlighted)
- Right panel: Character B's recent chronicle (events mentioning A highlighted)
- Centre panel: Mutual History — every relation change between A and B, with date, delta, and reason

---

## 14. Intrigue & Fog of Knowledge {#intrigue}

### Three Pillars of Intelligence

**Political Dominance** reveals: family trees, noble allegiances, marriage plans, council composition, succession order

**Economic Dominance** reveals: treasury levels, army supply costs, trade dependencies, bribe costs, market prices

**Espionage** reveals: secret plots, hidden bastards, assassinations, spy networks, private letters, hidden armies

### Intrigue Actions

*Placement:* Place Court Agent · Bribe Official · Cultivate Contact · Intercept Correspondence

*Intelligence:* Commission Merchant Report · Send Ambassador · Commission Spy Report

*Active Operations:* Sow Rumour · Forge Document · Arrange Accident · Turn Enemy Agent · Extract Person

*Counter-Intelligence:* Audit Council · Test Loyalty (deliberate false info to find leaks) · Honeypot Operation

### The False Chronicle

The most powerful intrigue tool — planting a false historical record in an enemy's chronicle. If successful, it creates manufactured "history" that other lords believe. If discovered, it causes a major diplomatic incident and damages the player's credibility with all factions.

---

## 15. AI Personality System {#ai}

### Eight Archetypes

Every NPC is a blend of two archetypes with one dominant. The combination produces distinct decision-making patterns.

| Archetype | Goal | Signature Action | Crusade |
|---|---|---|---|
| Expansionist (Bellator) | Maximum territory | MARCH_ARMY, DECLARE_WAR | Only if it opens eastern territory |
| Schemer (Intrigueur) | Eliminate rivals indirectly | PLACE_SPY, FABRICATE_CLAIM | Never — too far from network |
| Loyalist (Fidelis) | Support current power | PETITION_LIEGE, PROVIDE_SERVICE | Always answers |
| Reformer (Reformator) | Structural political change | FORM_FACTION, CREATE_CHARTER | If it boosts standing at home |
| Pragmatist (Opportunista) | Personal survival and advantage | Shifts each turn to back the stronger | Only if king goes |
| Pious (Devotus) | Church influence and crusade | DONATE_TO_CHURCH, TAKE_CRUSADE_VOW | First to volunteer |
| Warrior (Bellator Purus) | Military glory and fame | JOUST_TOURNAMENT, CHALLENGE_COMBAT | Eagerly — the ultimate arena |
| Builder (Constructor) | Economic and demographic growth | COMMISSION_MARKET, DEVELOP_FARMLAND | Never — bad for economy |

### AI Turn Decision Loop

Each turn, every NPC:
1. Reassesses goals based on current state
2. Identifies highest priority goal
3. Traverses the relationship graph to find the optimal action path
4. Samples a Gaussian to introduce human-feeling variance
5. Executes the highest-scoring affordable action

### Civil War Trigger

When kingdom stability drops below 18%, the most dissatisfied high noble raises rebellion. Knights choose sides based on their individual loyalty scores (Gaussian resolution). The aggregate retinue of each faction determines the outcome. This is explicitly non-deterministic — a smaller but luckier royalist force can defeat a larger rebel army.

---

## 16. Battle System (Phase 3) {#battles}

Phase 3 integrates Unreal Engine 5 real-time battles. Campaign outcomes trigger battle scenarios. Results feed back to the campaign as influence and satisfaction changes.

### UE5 Architecture

- **Mass Entity (ECS)** — All soldiers as mass entities. Target: 10,000 simultaneous agents at 60fps
- **Formation AI** — Knights hold ranks, infantry in shield walls, archers on flanks
- **Morale System** — Units route, rally, tire. Flanking breaks morale faster than casualties
- **Period Accuracy** — Heavy cavalry dominates. Longbowmen appear in Wales. No gunpowder

### Unit Types (1200–1300)

| Type | Role | Strength | Weakness |
|---|---|---|---|
| Men-at-Arms | Heavy cavalry | Devastating charge | Exhaustion, terrain |
| Knights | Elite cavalry | Leadership bonus | Chivalric code constraints |
| Feudal Levy | Infantry mass | Numbers | Shatters against knights |
| Crossbowmen | Ranged (controversial — banned vs Christians 1139) | Armour penetration | Slow reload |
| Welsh Longbowmen | Ranged | Range and rate of fire | Close combat |
| Siege Engineers | Support | Trebuchet deployment | Zero combat value |

---

## 17. Siege & Castle System {#sieges}

### Castle Evolution Timeline (1200–1300)

The 1200s represent the **golden age of castle architecture**:

- **Motte and Bailey** — Earthwork + wooden tower. Fast to build, easy to burn
- **Stone Keep** — Square tower. Strong, but corners can be mined (collapsed by sappers)
- **Shell Keep** — Ring wall on motte mound
- **Curtain Wall** — Stone enclosure with towers
- **Concentric Castle** — Multiple defensive rings. Dover, Caernarfon style. The peak of this period

### Trebuchet System

The trebuchet is the king of siege weapons in this era:

- Constructed on-site from timber resources (3–4 turns to build)
- Payload types: boulders (wall damage), firepots (incendiary), disease corpses (biological warfare)
- Vulnerable to garrison sorties — the castle can send forces out to burn siege engines
- Gaussian accuracy — same crew, same target, varying outcomes per shot

### Siege Mechanics

- **Garrison provisions** — Castles track food supply. Starving out a castle is a viable strategy
- **Anti-mining galleries** — Concentric castles can have counter-mining tunnels
- **Licence to Crenellate** — Building battlements without royal permission = illegal fortification = treason
- **Corner weakness** — Square keeps are particularly vulnerable to mining at the corners

---

## 18. Development Phases {#phases}

### Phase 1 — Foundation (Current)

**Goal:** Verify the core loop is fun before building complexity.

**Deliverables:**
- Clickable Godot 4 campaign map (55 counties, real geographic boundaries)
- Basic turn system (4 seasons per year, income collection)
- Two playable factions (England + France or England vs internal barons)
- Simple combat (army movement, auto-resolve with Gaussian outcomes)
- Basic noble system (King + 5 Earls, simple loyalty scores)
- One advisor message per turn
- Treasury tracking
- Win condition (capture enemy capital or achieve stability threshold)

Text labels mostly fit inside the regions. Either curve the text or wrap, dont curve the text if it fits.

We can have another overlay showing cities, castles, fiefs/key resources/mansions.
Text sometimes gets mushed in small sections. Allow wrapping where possible, make font smaller if needed.

Also add in the chronicle tab, Information about end turns, whether there was a good harvest etc etc needs to be recorded with color codes in the logs.
Need a table showing all baronaries , counties etc. in a cascading table. two tables needed, one by ownership, another by not owned. Show all related stats.
Also I added a sprite2D layer, I would like it to fit the background correctly. we can deal with that later if its too complicated.

Suggested next slices for the intrigue layer:

character_knowledge table (knower_id, target_id, fact_kind, fact_payload) so discoveries persist across turns and only the discoverer "knows" a hidden ambition.
Spymaster's spy_on_court discovery roll — when invoked against a target, roll vs. their intrigue stat; on success, INSERT a knowledge row revealing one fact (ambition, opinion of a third party, hidden marriage plans).
AI ambition driver in _advance_lifecycle — characters with attain_office who lack their target office periodically submit_action("appoint_office", liege=…, payload={office_key}) (currently the action is direct-resolve; gating on the liege's reply rolls them into the politics loop).
block_appointment and prevent_marriage action types that, when accepted, register a one-year veto on the corresponding event for the target.
Ambition reveal in the character panel when hidden=0 — small "Ambitions" section under the header showing the target office/region.

**Out of scope for Phase 1:**
- Family trees and bastards
- Full Chronicle / Bard system
- Intrigue and fog of knowledge

### Phase 2 — Political Depth

**Deliverables:**
- Full four-tier feudal node graph
- Complete action vocabulary per tier
- Bastard system with claim lifecycle
- Family tree UI (interactive graph)
- Advisor dialogue system (no explicit numbers — all implied)
- Fog of Knowledge (three pillars of intelligence)
- Living Chronicle (Scribe + Bard)
- Character Relations History (comparison view)
- Civil War trigger and resolution
- Castle construction (Licence to Crenellate)
- Full economy system (merchants, guilds, church spawning)
- AI personality archetypes (all eight)
- Crusade system

### Phase 3 — Military Layer

**Deliverables:**
- Real-time battles
- Castles and siege engines
- UE5 real-time battle integration
- Mass Entity unit simulation (10,000+ agents)
- Formation AI and morale system
- Trebuchet and siege engine mechanics
- Campaign → Battle → Campaign state pipeline
- Multi-faction battle scenarios

---

## 19. File Structure {#files}

```
medieval/
├── godot/                          ← Godot 4 project
│   ├── project.godot
│   ├── data/
│   │   └── england_godot.json      ← Processed map data
│   ├── scripts/
│   │   ├── MapData.gd              ← Autoload: map queries + polygon builder
│   │   ├── GameState.gd            ← Autoload: turn, factions, treasury
│   │   ├── FeudalGraph.gd          ← Relationship graph + traversal
│   │   ├── GaussianSystem.gd       ← Shared Gaussian sampling utilities
│   │   ├── AdvisorSystem.gd        ← Advisor message generation
│   │   ├── ChronicleSystem.gd      ← Event recording + Bard API calls
│   │   ├── AiController.gd         ← Per-NPC decision loop
│   │   └── CombatResolver.gd       ← Auto-resolve battle math
│   ├── scenes/
│   │   ├── CampaignMap.tscn        ← Main campaign map scene
│   │   ├── Region.tscn             ← Individual county node
│   │   ├── UI/
│   │   │   ├── InfoPanel.tscn
│   │   │   ├── AdvisorPanel.tscn
│   │   │   ├── FamilyTree.tscn
│   │   │   └── Chronicle.tscn
│   │   └── Modals/
│   │       ├── ChallengeModal.tscn
│   │       ├── CivilWarModal.tscn
│   │       └── PetitionModal.tscn
│   └── assets/
│       ├── fonts/                  ← UnifrakturMaguntia, Cinzel, Crimson Text
│       ├── shields/                ← Heraldic shield textures
│       └── ui/                     ← Panel backgrounds, decorations
├── tools/
│   ├── gb-topo_lad.json            ← Raw ONS boundary data
│   └── convert_to_godot.py        ← TopoJSON → Godot JSON pipeline
├── docs/
│   └── project.md                  ← This document
└── ue5/                            ← Phase 3 battle engine (future)
    └── MedievalBattle/
```

https://toppng.com/free-image/wikimedia-commons-english-coat-of-arms-medieval-banner-heraldry-medieval-PNG-free-PNG-Images_208751

---

## Design Notes — Ongoing

**On peasants:** Not individual characters. Population aggregate only. Drives economy spawning. No UI for individual peasant management.

**On the map:** Real ONS LAD boundary data projected with Mercator. 38,240 polygon points. Adjacency computed from shared arcs in TopoJSON topology. Do not hand-code any geographic coordinates.

**On the renderer:** Always use Compatibility (OpenGL 3.3) in Godot for the campaign layer. D3D12 / Forward+ is unstable on this hardware configuration and unnecessary for 2D.

**On the Bard:** The LLM integration is not a chatbot. It is a read-only narrator. It receives structured data (chronicle entries) and returns period-appropriate prose. The player cannot direct the narrative — only the game's systems can write history.

**On the Gaussian:** Never use deterministic thresholds for important outcomes. Always sample from a distribution. This is what makes the simulation feel alive rather than algorithmic.

**On scope:** Creative Assembly has 400+ people and 20+ years of iteration. The smart approach is to build the simplest version that is genuinely fun, verify the core loop, and then elaborate. Phase 1 should take weeks, not months.