# character_panel.gd
# A centred Panel showing one character: name + house, title, age, stats,
# current holdings, and immediate family. Built programmatically — no
# scene-authored fields. Triggered when the InfoPanel holder row is clicked
# (or when navigating from the family-tree view).
#
# A single instance lives under UI/Control; the parent (CampaignMap or
# ui_panel) calls `show_for(character_id)` to populate + reveal it.

extends Panel

signal closed
signal navigate_to(character_id: int)     # follow a Relations row
signal open_family_tree(character_id: int)

# Title text styles per gender, used as a fallback when characters.title is
# generic ("Lord"/"Lady") so the header reads a bit more grandly.
const TITLE_OVERRIDES := {
	"male":   ["Lord", "Sir"],
	"female": ["Lady", "Dame"],
}

var vbox: VBoxContainer
var _shown_character_id: int = 0


func _ready() -> void:
	# Centred, fixed size. The parent .tscn anchors this; we just style + build.
	custom_minimum_size = Vector2(560, 620)
	mouse_filter = Control.MOUSE_FILTER_STOP
	UITheme.style_panel(self)

	# Outer container.
	vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.offset_left = 18
	vbox.offset_top = 14
	vbox.offset_right = -18
	vbox.offset_bottom = -14
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)
	visible = false


# Esc closes the panel when it's the active prompt. Uses _input + accept_event
# so the keypress is consumed before CampaignMap._unhandled_input fires its
# own ESC handler (which would otherwise clear the map selection too).
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			accept_event()


func show_for(character_id: int) -> void:
	_shown_character_id = character_id
	_rebuild()
	visible = true


func close() -> void:
	visible = false
	closed.emit()


func _rebuild() -> void:
	for child in vbox.get_children():
		child.queue_free()
	if _shown_character_id <= 0:
		_label("No character selected.", 16, Color.WHITE)
		return
	var ch: Dictionary = GameState.character(_shown_character_id)
	if ch.is_empty():
		_label("Character #%d not found." % _shown_character_id, 16, Color(1, 0.6, 0.6))
		return

	_build_header(ch)
	_build_stats(ch)
	_build_offices(ch)
	_build_holdings(ch)
	_build_relations(ch)
	_build_lifecycle(ch)
	_build_actions(ch)
	_build_inbox(ch)
	_build_footer(ch)


func _build_header(ch: Dictionary) -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	vbox.add_child(top)

	# Portrait placeholder.
	var portrait := ColorRect.new()
	portrait.custom_minimum_size = Vector2(80, 96)
	portrait.color = Color(0.18, 0.13, 0.08)
	top.add_child(portrait)
	var initials := Label.new()
	initials.text = (str(ch.get("given_name", "?")).substr(0, 1) +
			str(ch.get("surname", "?")).substr(0, 1)).to_upper()
	initials.add_theme_font_size_override("font_size", 36)
	initials.add_theme_color_override("font_color", Color(0.85, 0.78, 0.50))
	initials.size_flags_vertical = Control.SIZE_EXPAND_FILL
	initials.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initials.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	initials.anchor_right = 1.0
	initials.anchor_bottom = 1.0
	portrait.add_child(initials)

	# Right column — name + title + age.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 2)
	top.add_child(right)

	var name_lbl := Label.new()
	var full_name: String = (str(ch.get("given_name", "")) + " " + str(ch.get("surname", ""))).strip_edges()
	if not bool(ch.get("alive", true)):
		full_name += "  †"
	name_lbl.text = full_name
	name_lbl.add_theme_font_size_override("font_size", 26)
	name_lbl.add_theme_color_override("font_color", Color(0.95, 0.88, 0.62))
	name_lbl.add_theme_constant_override("outline_size", 1)
	name_lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.01))
	right.add_child(name_lbl)

	# Title + "of House [Surname]" — the surname is a button that opens the
	# family tree. Built as an HBoxContainer so the surname keeps its hover
	# tint without underlining the whole "Duke of House" prefix.
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 4)
	right.add_child(title_row)
	var title_lbl := Label.new()
	var title: String = str(ch.get("title", "Lord"))
	var house: String = str(ch.get("surname", ""))
	title_lbl.text = "%s of House" % title if house != "" else title
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_lbl.add_theme_color_override("font_color", Color(0.75, 0.70, 0.55))
	title_row.add_child(title_lbl)
	if house != "":
		var house_btn := Button.new()
		house_btn.text = house
		house_btn.flat = true
		house_btn.add_theme_font_size_override("font_size", 14)
		house_btn.add_theme_color_override("font_color", Color(0.95, 0.85, 0.45))
		house_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.55))
		var cid_for_house: int = int(ch.get("character_id", 0))
		house_btn.pressed.connect(func(): open_family_tree.emit(cid_for_house))
		title_row.add_child(house_btn)

	var meta_lbl := Label.new()
	meta_lbl.text = "%s · %d years" % [str(ch.get("gender", "?")).capitalize(), int(ch.get("age", 0))]
	meta_lbl.add_theme_font_size_override("font_size", 12)
	meta_lbl.add_theme_color_override("font_color", Color(0.60, 0.55, 0.42))
	right.add_child(meta_lbl)

	if int(ch.get("prestige", 0)) > 0:
		var prestige := Label.new()
		prestige.text = "House prestige: %d" % int(ch.get("prestige", 0))
		prestige.add_theme_font_size_override("font_size", 11)
		prestige.add_theme_color_override("font_color", Color(0.55, 0.50, 0.38))
		right.add_child(prestige)

	vbox.add_child(HSeparator.new())


func _build_stats(ch: Dictionary) -> void:
	_section_header("Stats")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 4)
	vbox.add_child(grid)
	const KEYS := ["martial", "diplomacy", "stewardship", "intrigue", "piety"]
	for k in KEYS:
		var key_lbl := Label.new()
		key_lbl.text = String(k).capitalize()
		key_lbl.add_theme_font_size_override("font_size", 12)
		key_lbl.add_theme_color_override("font_color", Color(0.65, 0.60, 0.50))
		grid.add_child(key_lbl)
		var val_lbl := Label.new()
		val_lbl.text = str(int(ch.get(k, 0)))
		val_lbl.add_theme_font_size_override("font_size", 13)
		val_lbl.add_theme_color_override("font_color", Color(0.95, 0.92, 0.80))
		grid.add_child(val_lbl)


func _build_holdings(ch: Dictionary) -> void:
	var rows: Array = GameState.holdings_of(int(ch.get("character_id", 0)))
	if rows.is_empty():
		return
	_section_header("Holdings")
	for r in rows:
		var lbl := Label.new()
		lbl.text = "  · %s — %s" % [str(r.region_type).capitalize(), _pretty_region(r)]
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.85, 0.80, 0.65))
		vbox.add_child(lbl)


func _pretty_region(r: Dictionary) -> String:
	# County and country IDs are already human-readable. Duchies are lowercase
	# slugs; baronies are LAD13CDs — show what we can.
	var rid: String = str(r.region_id)
	match str(r.region_type):
		"country": return rid.capitalize()
		"duchy":
			var d: Dictionary = MapData.duchies.get(rid, {})
			return str(d.get("name", rid))
		"county":  return rid
		"barony":
			# Look up name from the geometry side via DesignData/MapData if possible.
			var dd: Node = get_node_or_null("/root/DesignData")
			if dd != null:
				var b: Dictionary = dd.baronies.get(rid, {})
				if "name" in b:
					return "%s (%s)" % [str(b.name), rid]
			return rid
	return rid


func _build_relations(ch: Dictionary) -> void:
	var rels: Array = GameState.relations_of(int(ch.get("character_id", 0)))
	if rels.is_empty():
		return
	_section_header("Family")
	# Group by kind for clean display.
	var grouped: Dictionary = {}
	for r in rels:
		var k: String = str(r.kind)
		if not grouped.has(k):
			grouped[k] = []
		grouped[k].append(r.other)
	for kind in ["parent", "spouse", "sibling", "child"]:
		if not grouped.has(kind):
			continue
		for other in grouped[kind]:
			_relation_row(_relation_label(kind, other), other)


func _relation_label(kind: String, other: Dictionary) -> String:
	var gender: String = str(other.get("gender", "male"))
	match kind:
		"spouse": return "Wife" if gender == "female" else "Husband"
		"parent": return "Mother" if gender == "female" else "Father"
		"child":  return "Daughter" if gender == "female" else "Son"
		"sibling": return "Sister" if gender == "female" else "Brother"
	return kind.capitalize()


func _relation_row(role: String, other: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	var role_lbl := Label.new()
	role_lbl.text = role
	role_lbl.custom_minimum_size.x = 70
	role_lbl.add_theme_font_size_override("font_size", 12)
	role_lbl.add_theme_color_override("font_color", Color(0.55, 0.50, 0.38))
	row.add_child(role_lbl)

	var name_btn := Button.new()
	var full: String = (str(other.get("given_name", "")) + " " + str(other.get("surname", ""))).strip_edges()
	if not bool(other.get("alive", true)):
		full += " †"
	name_btn.text = full + "  · " + str(int(other.get("age", 0)))
	name_btn.flat = true
	name_btn.add_theme_font_size_override("font_size", 13)
	name_btn.add_theme_color_override("font_color", Color(0.95, 0.90, 0.70))
	name_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.55))
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.pressed.connect(func(): navigate_to.emit(int(other.get("character_id", 0))))
	row.add_child(name_btn)


func _build_offices(ch: Dictionary) -> void:
	var offices: Array = GameState.offices_of(int(ch.get("character_id", 0)))
	if offices.is_empty():
		return
	_section_header("Offices")
	for o in offices:
		var lbl := Label.new()
		lbl.text = "  · %s of %s — %s" % [
			str(o.office_key).capitalize(),
			str(o.region_id).capitalize() if str(o.region_type) == "country" else str(o.region_id),
			str(o.region_type).capitalize(),
		]
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.85, 0.78, 0.55))
		vbox.add_child(lbl)


# Lifecycle events log: birth, coming of age, marriages, widowing, death.
# Compact one-line-per-event listing in chronological order.
func _build_lifecycle(ch: Dictionary) -> void:
	var cid: int = int(ch.get("character_id", 0))
	if cid <= 0:
		return
	var events: Array = GameState.lifecycle_events_of(cid)
	if events.is_empty():
		return
	_section_header("Life events")
	for e in events:
		var lbl := Label.new()
		lbl.text = "  · %d — %s" % [int(e.get("year", 0)), _pretty_event(str(e.get("kind", "")))]
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", UITheme.COL_INK_DIM)
		vbox.add_child(lbl)


func _pretty_event(kind: String) -> String:
	match kind:
		"birth":                return "born"
		"coming_of_age":        return "came of age"
		"marriage":             return "married"
		"widowed":              return "widowed"
		"death":                return "died"
		"inherited":            return "inherited a holding"
		"inheritance_blocked":  return "inheritance blocked by liege"
		"escheated":            return "received an escheated holding"
	return kind


# Actions the PLAYER character can take against the character currently
# being viewed. If the player is looking at themselves, shows self-actions.
# Each action becomes a button; pressing it calls GameState.submit_action.
func _build_actions(ch: Dictionary) -> void:
	var player_cid: int = GameState.player_character_id()
	var subject_cid: int = int(ch.get("character_id", 0))
	if player_cid <= 0 or subject_cid <= 0:
		return
	if player_cid == subject_cid:
		# Don't show actions on yourself for now — placeholder until
		# self-actions (take vows, study, etc.) are designed.
		return
	var actions: Array = GameState.available_actions(player_cid, subject_cid)
	# Show current opinion between actor and subject for context.
	var op_yours: int = GameState.opinion_of(player_cid, subject_cid)
	var op_theirs: int = GameState.opinion_of(subject_cid, player_cid)
	_section_header("Diplomacy")
	var op_row := Label.new()
	op_row.text = "  your opinion: %+d   ·   their opinion: %+d" % [op_yours, op_theirs]
	op_row.add_theme_font_size_override("font_size", 11)
	op_row.add_theme_color_override("font_color", Color(0.65, 0.60, 0.50))
	vbox.add_child(op_row)
	if actions.is_empty():
		var no_act := Label.new()
		no_act.text = "  (no actions available — no liege/vassal link)"
		no_act.add_theme_font_size_override("font_size", 11)
		no_act.add_theme_color_override("font_color", Color(0.45, 0.40, 0.30))
		vbox.add_child(no_act)
		return
	for a in actions:
		var btn := Button.new()
		btn.text = "  ▸  " + str(a.label)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.tooltip_text = str(a.description)
		var key: String = str(a.key)
		btn.pressed.connect(func(): _on_action_pressed(key, subject_cid))
		vbox.add_child(btn)


# Incoming requests aimed at this character. Each pending row gets accept/
# decline buttons; the resolution updates opinion in both directions.
func _build_inbox(ch: Dictionary) -> void:
	var cid: int = int(ch.get("character_id", 0))
	var inbox: Array = GameState.pending_actions_for(cid)
	if inbox.is_empty():
		return
	_section_header("Inbox")
	for row in inbox:
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 6)
		vbox.add_child(item)
		var desc := Label.new()
		var initiator: String = "%s %s" % [
			str(row.get("initiator_given", "?")),
			str(row.get("initiator_surname", "")),
		]
		desc.text = "  %s — %s" % [str(row.action_type), initiator.strip_edges()]
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color(0.85, 0.80, 0.65))
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.add_child(desc)
		var aid: int = int(row.id)
		var accept := Button.new()
		accept.text = "Accept"
		accept.pressed.connect(func(): _resolve_inbox_item(aid, true))
		item.add_child(accept)
		var decline := Button.new()
		decline.text = "Decline"
		decline.pressed.connect(func(): _resolve_inbox_item(aid, false))
		item.add_child(decline)


func _on_action_pressed(action_key: String, subject_cid: int) -> void:
	var actor: int = GameState.player_character_id()
	GameState.submit_action(action_key, actor, subject_cid, {})
	# Rebuild so the opinion + inbox sections refresh.
	_rebuild()


func _resolve_inbox_item(action_id: int, accept: bool) -> void:
	GameState.resolve_action(action_id, accept, "")
	_rebuild()


func _build_footer(ch: Dictionary) -> void:
	vbox.add_child(HSeparator.new())
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)
	var tree_btn := Button.new()
	tree_btn.text = "🌳 Family tree"
	tree_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree_btn.pressed.connect(func(): open_family_tree.emit(int(ch.get("character_id", 0))))
	btn_row.add_child(tree_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	btn_row.add_child(close_btn)


func _section_header(text: String) -> void:
	var h := Label.new()
	h.text = text.to_upper()
	h.add_theme_font_size_override("font_size", 11)
	h.add_theme_color_override("font_color", Color(0.85, 0.78, 0.55))
	vbox.add_child(h)
	var sep := HSeparator.new()
	vbox.add_child(sep)


func _label(text: String, font_size: int, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	vbox.add_child(l)
