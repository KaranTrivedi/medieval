# character_panel.gd
# Centred modal showing one character. Tabbed layout:
#   • Overview   — header (portrait, name, title, age, prestige) + 2-column
#                  body with Stats / Holdings / Offices on the left and Family
#                  on the right.
#   • History    — chronological lifecycle event log.
#   • Diplomacy  — opinion display, action buttons, and pending inbox.
# Footer outside the tabs holds Family-Tree and Close buttons.
#
# Triggered via `show_for(character_id)` from CampaignMap / region panel /
# family-tree panel. Always brings itself to the front so it stacks above
# other open modals.

extends Panel

signal closed
signal navigate_to(character_id: int)     # follow a Relations row
signal open_family_tree(character_id: int)

var _root: VBoxContainer
var _tabs: TabContainer
var _shown_character_id: int = 0
# Active tab is remembered across rebuilds. Without this, every click that
# triggers _rebuild (e.g. an action button, the inbox accept/decline) would
# snap the user back to the first tab because the TabContainer is recreated.
var _active_tab: int = 0


func _ready() -> void:
	custom_minimum_size = Vector2(880, 640)
	mouse_filter = Control.MOUSE_FILTER_STOP
	UITheme.style_panel(self)

	_root = VBoxContainer.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.offset_left = 18
	_root.offset_top = 14
	_root.offset_right = -18
	_root.offset_bottom = -14
	_root.add_theme_constant_override("separation", 10)
	add_child(_root)
	visible = false


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
	_raise_to_front()


# Bump this panel to the top of its parent's child list so it draws above
# any sibling modal (e.g. RegionPanel) that was already open.
func _raise_to_front() -> void:
	var p := get_parent()
	if p != null:
		p.move_child(self, p.get_child_count() - 1)


func close() -> void:
	visible = false
	closed.emit()


# ── REBUILD ─────────────────────────────────────────────────────────────────

func _rebuild() -> void:
	for child in _root.get_children():
		child.queue_free()
	if _shown_character_id <= 0:
		_root.add_child(UITheme.text_label("No character selected.", 14))
		return
	var ch: Dictionary = GameState.character(_shown_character_id)
	if ch.is_empty():
		_root.add_child(UITheme.text_label("Character #%d not found." % _shown_character_id, 14, Color(1, 0.6, 0.6)))
		return

	_build_header(ch)
	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_stylebox_override("panel", UITheme.tab_panel_stylebox())
	_root.add_child(_tabs)
	_tabs.add_child(_build_overview_tab(ch))
	_tabs.add_child(_build_history_tab(ch))
	_tabs.add_child(_build_diplomacy_tab(ch))
	_tabs.set_tab_title(0, "Overview")
	_tabs.set_tab_title(1, "History")
	_tabs.set_tab_title(2, "Diplomacy")
	# Restore the previously-active tab (defaults to 0 on first build).
	# Clamp in case tab count changes between rebuilds.
	_tabs.current_tab = clampi(_active_tab, 0, _tabs.get_tab_count() - 1)
	_tabs.tab_changed.connect(func(idx): _active_tab = int(idx))

	_build_footer(ch)


# ── HEADER ──────────────────────────────────────────────────────────────────

func _build_header(ch: Dictionary) -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	_root.add_child(top)

	# Header layout — portrait + info column expand; Close button is pinned
	# to the top-right so it lands in the same spot on every panel.

	# Portrait placeholder — initials over a parchment-dark square.
	var portrait := ColorRect.new()
	portrait.custom_minimum_size = Vector2(88, 96)
	portrait.color = Color(0.14, 0.10, 0.06)
	top.add_child(portrait)
	var initials := Label.new()
	initials.text = (str(ch.get("given_name", "?")).substr(0, 1)
			+ str(ch.get("surname", "?")).substr(0, 1)).to_upper()
	initials.add_theme_font_size_override("font_size", 36)
	initials.add_theme_color_override("font_color", UITheme.COL_ACCENT_GOLD_DIM)
	initials.size_flags_vertical = Control.SIZE_EXPAND_FILL
	initials.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initials.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	initials.anchor_right = 1.0
	initials.anchor_bottom = 1.0
	portrait.add_child(initials)

	# Right column — name + title + age + prestige.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 2)
	top.add_child(right)

	var alive: bool = bool(ch.get("alive", true))
	var name_lbl := Label.new()
	var full_name: String = (str(ch.get("given_name", "")) + " "
			+ str(ch.get("surname", ""))).strip_edges()
	if not alive:
		full_name += "  ✝"
	name_lbl.text = full_name
	name_lbl.add_theme_font_size_override("font_size", 26)
	name_lbl.add_theme_color_override("font_color",
			UITheme.COL_INK_DEAD if not alive else UITheme.COL_ACCENT_GOLD)
	name_lbl.add_theme_constant_override("outline_size", 1)
	name_lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.01))
	right.add_child(name_lbl)

	# Title row. Reads "Duke, head of House Lacy" for landed characters; for
	# non-holders it reads "Member of House Lacy". The House surname is a
	# button that opens the family tree.
	right.add_child(_build_title_row(ch))

	var meta_lbl := Label.new()
	meta_lbl.text = "%s · %d years" % [
		str(ch.get("gender", "?")).capitalize(),
		int(ch.get("age", 0)),
	]
	meta_lbl.add_theme_font_size_override("font_size", 12)
	meta_lbl.add_theme_color_override("font_color", UITheme.COL_INK_MUTED)
	right.add_child(meta_lbl)

	if int(ch.get("prestige", 0)) > 0:
		var p := Label.new()
		p.text = "House prestige: %d" % int(ch.get("prestige", 0))
		p.add_theme_font_size_override("font_size", 11)
		p.add_theme_color_override("font_color", UITheme.COL_INK_MUTED)
		right.add_child(p)

	# Close button — pinned to the header's top-right so the close affordance
	# is in the same spot on every panel in the project.
	var close_col := VBoxContainer.new()
	close_col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.add_child(close_col)
	var close_btn := UITheme.styled_button("✕")
	close_btn.tooltip_text = "Close (Esc)"
	close_btn.pressed.connect(close)
	close_col.add_child(close_btn)


# Produce the line that follows the name. Format depends on whether the
# character is the holder of any region:
#   • holder       → "<Title>, head of House <Surname>"
#   • non-holder   → "Member of House <Surname>"
# The surname is rendered as a flat Button that opens the family tree.
func _build_title_row(ch: Dictionary) -> Control:
	var cid: int = int(ch.get("character_id", 0))
	var holdings: Array = GameState.holdings_of(cid) if cid > 0 else []
	var is_head: bool = not holdings.is_empty()
	var house: String = str(ch.get("surname", "")).strip_edges()
	var title: String = str(ch.get("title", "Lord"))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var prefix := Label.new()
	if house == "":
		prefix.text = title
	elif is_head:
		prefix.text = "%s, head of House" % title
	else:
		prefix.text = "Member of House"
	prefix.add_theme_font_size_override("font_size", 14)
	prefix.add_theme_color_override("font_color", UITheme.COL_INK_DIM)
	row.add_child(prefix)

	if house != "":
		var house_btn := Button.new()
		house_btn.text = house
		house_btn.flat = true
		house_btn.add_theme_font_size_override("font_size", 14)
		house_btn.add_theme_color_override("font_color", UITheme.COL_ACCENT_GOLD)
		house_btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
		house_btn.tooltip_text = "Open family tree of House " + house
		house_btn.pressed.connect(func(): open_family_tree.emit(int(ch.get("character_id", 0))))
		row.add_child(house_btn)

	return row


# ── OVERVIEW TAB (two-column) ───────────────────────────────────────────────

func _build_overview_tab(ch: Dictionary) -> Control:
	# Wrap the whole Overview body in a ScrollContainer so a lord with many
	# vassals (or any long section) doesn't push the footer's Family-tree
	# button off the panel — that was the spill-out the user reported.
	var col := VBoxContainer.new()
	col.name = "Overview"
	col.add_theme_constant_override("separation", 8)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 20)
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(split)

	# LEFT: Stats / Offices / Holdings / Vassals.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.0
	left.add_theme_constant_override("separation", 12)
	split.add_child(left)
	_build_stats(left, ch)
	_build_offices(left, ch)
	_build_holdings(left, ch)
	_build_vassals(left, ch)

	# RIGHT: Family.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.0
	right.add_theme_constant_override("separation", 12)
	split.add_child(right)
	_build_relations(right, ch)

	return col


func _build_stats(parent: Control, ch: Dictionary) -> void:
	parent.add_child(UITheme.section_header("Stats"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 4)
	parent.add_child(grid)
	const KEYS := ["martial", "diplomacy", "stewardship", "intrigue", "piety"]
	for k in KEYS:
		grid.add_child(UITheme.dim_label(String(k).capitalize(), 12))
		var v := UITheme.text_label(str(int(ch.get(k, 0))), 13)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(v)


func _build_holdings(parent: Control, ch: Dictionary) -> void:
	var rows: Array = GameState.holdings_of(int(ch.get("character_id", 0)))
	if rows.is_empty():
		return
	parent.add_child(UITheme.section_header("Holdings"))
	for r in rows:
		var lbl := UITheme.text_label(
			"· %s — %s" % [str(r.region_type).capitalize(), _pretty_region(r)],
			12, UITheme.COL_INK)
		parent.add_child(lbl)


# Vassals section — every sub-region holder that answers to this character
# across all of their holdings. Each row is a clickable button that routes
# to the vassal's character panel via NavRouter.
func _build_vassals(parent: Control, ch: Dictionary) -> void:
	var cid: int = int(ch.get("character_id", 0))
	if cid <= 0:
		return
	var vassals: Array = GameState.vassals_of(cid)
	if vassals.is_empty():
		return
	parent.add_child(UITheme.section_header("Vassals"))
	for v in vassals:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		parent.add_child(row)
		# Region context (compact, dim).
		var region_lbl := UITheme.dim_label(
			"%s · %s" % [
				str(v.get("region_type", "")).capitalize(),
				str(v.get("region_id", "")),
			], 11)
		region_lbl.custom_minimum_size.x = 130
		row.add_child(region_lbl)
		var alive: bool = bool(v.get("alive", true))
		var name_btn := Button.new()
		name_btn.flat = true
		var dagger: String = "  ✝" if not alive else ""
		name_btn.text = "%s %s%s" % [
			str(v.get("given_name", "")),
			str(v.get("surname", "")),
			dagger,
		]
		name_btn.add_theme_font_size_override("font_size", 12)
		name_btn.add_theme_color_override("font_color",
				UITheme.COL_INK_DEAD if not alive else UITheme.COL_INK)
		name_btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
		name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var vcid: int = int(v.get("character_id", 0))
		name_btn.pressed.connect(func(): navigate_to.emit(vcid))
		row.add_child(name_btn)


func _build_offices(parent: Control, ch: Dictionary) -> void:
	var offices: Array = GameState.offices_of(int(ch.get("character_id", 0)))
	if offices.is_empty():
		return
	parent.add_child(UITheme.section_header("Offices"))
	for o in offices:
		var rid_label: String = str(o.region_id).capitalize() if str(o.region_type) == "country" else str(o.region_id)
		var lbl := UITheme.text_label(
			"· %s of %s — %s" % [str(o.office_key).capitalize(), rid_label, str(o.region_type).capitalize()],
			12, UITheme.COL_INK)
		parent.add_child(lbl)


func _build_relations(parent: Control, ch: Dictionary) -> void:
	var rels: Array = GameState.relations_of(int(ch.get("character_id", 0)))
	if rels.is_empty():
		parent.add_child(UITheme.section_header("Family"))
		parent.add_child(UITheme.dim_label("(no recorded relations)", 11))
		return
	parent.add_child(UITheme.section_header("Family"))
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
			parent.add_child(_relation_row(_relation_label(kind, other), other))


# ── HISTORY TAB ─────────────────────────────────────────────────────────────

func _build_history_tab(ch: Dictionary) -> Control:
	var col := VBoxContainer.new()
	col.name = "History"
	col.add_theme_constant_override("separation", 4)
	var cid: int = int(ch.get("character_id", 0))
	var events: Array = GameState.lifecycle_events_of(cid) if cid > 0 else []
	if events.is_empty():
		col.add_child(UITheme.dim_label("(no recorded life events)", 12))
		return col
	# Scrollable in case a long-lived character racks up many events.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)
	for e in events:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var year_lbl := UITheme.dim_label(str(int(e.get("year", 0))), 12)
		year_lbl.custom_minimum_size.x = 60
		row.add_child(year_lbl)
		var kind_lbl := UITheme.text_label(_pretty_event(
			str(e.get("kind", "")), str(e.get("payload_json", "{}"))), 12)
		row.add_child(kind_lbl)
		list.add_child(row)
	return col


# Render one lifecycle event line. Office-related events read payload_json
# so the line reflects which office and where (e.g. "appointed Marshal of
# England" rather than just "appointed").
func _pretty_event(kind: String, payload_json: String = "{}") -> String:
	match kind:
		"birth":                return "born"
		"coming_of_age":        return "came of age"
		"marriage":             return "married"
		"widowed":              return "widowed"
		"death":                return "died"
		"inherited":            return "inherited a holding"
		"inheritance_blocked":  return "inheritance blocked by liege"
		"escheated":            return "received an escheated holding"
		"appointed":            return "appointed " + _office_event_phrase(payload_json)
		"dismissed":            return "dismissed " + _office_event_phrase(payload_json)
	return kind


# Turn a JSON payload of {office, region_type, region_id} into a readable
# phrase like "Marshal of England" / "Sheriff of Yorkshire".
func _office_event_phrase(payload_json: String) -> String:
	var parser := JSON.new()
	if parser.parse(payload_json) != OK:
		return ""
	var p: Dictionary = parser.get_data()
	var office: String = str(GameState.OFFICE_LABELS.get(
			str(p.get("office", "")), str(p.get("office", "")).capitalize()))
	var rid: String = str(p.get("region_id", "")).capitalize() if str(p.get("region_type", "")) == "country" else str(p.get("region_id", ""))
	if office == "" or rid == "":
		return ""
	return "%s of %s" % [office, rid]


# ── DIPLOMACY TAB ───────────────────────────────────────────────────────────

func _build_diplomacy_tab(ch: Dictionary) -> Control:
	var col := VBoxContainer.new()
	col.name = "Diplomacy"
	col.add_theme_constant_override("separation", 10)
	var subject_cid: int = int(ch.get("character_id", 0))
	var player_cid: int = GameState.player_character_id()
	var family_prestige: int = int(ch.get("prestige", 0))

	# Opinion (only meaningful for non-self).
	if player_cid > 0 and subject_cid > 0 and player_cid != subject_cid:
		col.add_child(UITheme.section_header("Opinion"))
		var op_yours: int = GameState.opinion_of(player_cid, subject_cid)
		var op_theirs: int = GameState.opinion_of(subject_cid, player_cid)
		col.add_child(UITheme.text_label(
			"Your opinion: %+d         Their opinion of you: %+d" % [op_yours, op_theirs],
			12, UITheme.COL_INK))

	# Their available actions — every action this character qualifies for,
	# filtered by office only (direction is not relevant when SHOWING the
	# privilege list). Office-granted entries pick up the bordered tooltip
	# treatment in _build_action_button.
	var their_actions: Array = GameState.actions_for(subject_cid)
	col.add_child(UITheme.section_header("Actions available to %s   (prestige %d)" % [
		str(ch.get("given_name", "this character")), family_prestige]))
	if their_actions.is_empty():
		col.add_child(UITheme.dim_label("(no actions available from current rank / office)", 11))
	else:
		for a in their_actions:
			# Display-only when the subject isn't the player; clickable when it
			# IS the player (i.e. you're viewing yourself).
			var clickable: bool = (subject_cid == player_cid)
			col.add_child(_build_action_button(a, family_prestige, clickable, player_cid))

	# Player-on-subject actions — only when viewing someone else.
	if player_cid > 0 and subject_cid > 0 and player_cid != subject_cid:
		var your_actions: Array = GameState.available_actions(player_cid, subject_cid)
		col.add_child(UITheme.section_header("Your actions toward them"))
		if your_actions.is_empty():
			col.add_child(UITheme.dim_label("(no actions — no liege/vassal link)", 11))
		else:
			# Player's own family prestige — pull from the player character row.
			var player_prestige: int = int(GameState.character(player_cid).get("prestige", 0))
			for a in your_actions:
				col.add_child(_build_action_button(a, player_prestige, true, subject_cid))

	# Inbox — pending actions awaiting THIS character's response.
	var inbox: Array = GameState.pending_actions_for(subject_cid)
	col.add_child(UITheme.section_header("Inbox"))
	if inbox.is_empty():
		col.add_child(UITheme.dim_label("(no pending requests)", 11))
	else:
		for row in inbox:
			var item := HBoxContainer.new()
			item.add_theme_constant_override("separation", 6)
			col.add_child(item)
			var initiator: String = "%s %s" % [
				str(row.get("initiator_given", "?")),
				str(row.get("initiator_surname", "")),
			]
			var desc := UITheme.text_label(
				"%s — from %s" % [str(row.action_type), initiator.strip_edges()],
				12, UITheme.COL_INK)
			desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			item.add_child(desc)
			var aid: int = int(row.id)
			var accept := UITheme.styled_button("Accept")
			accept.pressed.connect(func(): _resolve_inbox_item(aid, true))
			item.add_child(accept)
			var decline := UITheme.styled_button("Decline")
			decline.pressed.connect(func(): _resolve_inbox_item(aid, false))
			item.add_child(decline)
	return col


# Build one action row. Office-gated actions get a gold border + the "privilege
# of <office>" tooltip suffix. Disabled when the actor can't afford the
# prestige cost. `pressed_target_cid` is the id passed to submit_action.
func _build_action_button(action: Dictionary, prestige_budget: int,
		clickable: bool, pressed_target_cid: int) -> Control:
	var label: String = "▸  " + str(action.get("label", action.get("key", "")))
	var cost: int = int(action.get("prestige_cost", 0))
	if cost > 0:
		label += "   (%d prestige)" % cost
	var btn := UITheme.styled_button(label)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	# Tooltip: description, plus a "privilege of <office>" suffix when gated.
	var tip: String = str(action.get("description", ""))
	if "requires_office" in action:
		var off_key: String = str(action["requires_office"])
		var off_label: String = str(GameState.OFFICE_LABELS.get(off_key, off_key.capitalize()))
		tip += "\n\n(privilege of %s)" % off_label
		# Gold-bordered stylebox flags this as an office-granted action.
		_apply_office_stylebox(btn)
	btn.tooltip_text = tip
	# Affordability gate. Visually fade + disable when the actor can't pay.
	if cost > prestige_budget:
		btn.disabled = true
		btn.modulate = Color(1, 1, 1, 0.55)
	if not clickable:
		btn.disabled = true
		btn.focus_mode = Control.FOCUS_NONE
	if clickable and not btn.disabled:
		var key: String = str(action.get("key", ""))
		btn.pressed.connect(func(): _on_action_pressed(key, pressed_target_cid))
	return btn


# Replace the styled button's normal/hover styleboxes with gold-bordered
# variants so office-granted actions stand out from the base set.
func _apply_office_stylebox(btn: Button) -> void:
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		match state:
			"pressed": sb.bg_color = Color(0.22, 0.17, 0.08)
			"hover":   sb.bg_color = Color(0.18, 0.13, 0.07)
			_:         sb.bg_color = Color(0.13, 0.10, 0.05)
		sb.border_color = UITheme.COL_ACCENT_GOLD
		sb.border_width_left = 2
		sb.border_width_top = 2
		sb.border_width_right = 2
		sb.border_width_bottom = 2
		sb.corner_radius_top_left = 2
		sb.corner_radius_top_right = 2
		sb.corner_radius_bottom_left = 2
		sb.corner_radius_bottom_right = 2
		sb.content_margin_left = 10
		sb.content_margin_right = 10
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		btn.add_theme_stylebox_override(state, sb)
	btn.add_theme_color_override("font_color", UITheme.COL_ACCENT_GOLD)


# ── FOOTER ──────────────────────────────────────────────────────────────────

func _build_footer(ch: Dictionary) -> void:
	var sep := HSeparator.new()
	_root.add_child(sep)
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	_root.add_child(btn_row)
	# Close lives in the header (top-right). Footer keeps action-style buttons.
	var tree_btn := UITheme.styled_button("🌳  Family tree")
	tree_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree_btn.pressed.connect(func(): open_family_tree.emit(int(ch.get("character_id", 0))))
	btn_row.add_child(tree_btn)


# ── EVENT HANDLERS ──────────────────────────────────────────────────────────

func _on_action_pressed(action_key: String, subject_cid: int) -> void:
	var actor: int = GameState.player_character_id()
	GameState.submit_action(action_key, actor, subject_cid, {})
	_rebuild()


func _resolve_inbox_item(action_id: int, accept: bool) -> void:
	GameState.resolve_action(action_id, accept, "")
	_rebuild()


# ── SMALL HELPERS ───────────────────────────────────────────────────────────

func _relation_label(kind: String, other: Dictionary) -> String:
	var gender: String = str(other.get("gender", "male"))
	match kind:
		"spouse": return "Wife" if gender == "female" else "Husband"
		"parent": return "Mother" if gender == "female" else "Father"
		"child":  return "Daughter" if gender == "female" else "Son"
		"sibling": return "Sister" if gender == "female" else "Brother"
	return kind.capitalize()


func _relation_row(role: String, other: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var role_lbl := UITheme.dim_label(role, 12)
	role_lbl.custom_minimum_size.x = 70
	row.add_child(role_lbl)
	var alive: bool = bool(other.get("alive", true))
	var name_btn := Button.new()
	var full: String = (str(other.get("given_name", "")) + " "
			+ str(other.get("surname", ""))).strip_edges()
	if not alive:
		full += " ✝"
	name_btn.text = full + "  · " + str(int(other.get("age", 0)))
	name_btn.flat = true
	name_btn.add_theme_font_size_override("font_size", 13)
	name_btn.add_theme_color_override("font_color",
			UITheme.COL_INK_DEAD if not alive else UITheme.COL_INK)
	name_btn.add_theme_color_override("font_hover_color", UITheme.COL_BUTTON_HOVER)
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.pressed.connect(func(): navigate_to.emit(int(other.get("character_id", 0))))
	row.add_child(name_btn)
	return row


func _pretty_region(r: Dictionary) -> String:
	var rid: String = str(r.region_id)
	match str(r.region_type):
		"country": return rid.capitalize()
		"duchy":
			var d: Dictionary = MapData.duchies.get(rid, {})
			return str(d.get("name", rid))
		"county":  return rid
		"barony":
			var dd: Node = get_node_or_null("/root/DesignData")
			if dd != null:
				var b: Dictionary = dd.baronies.get(rid, {})
				if "name" in b:
					return "%s (%s)" % [str(b.name), rid]
			return rid
	return rid
