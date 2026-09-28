package main

// Placeholder menus: Dear ImGui windows standing in for the player's screens until the Lua UI has
// them (ui/source.odin). Like Skyrim's, they pause the world (no tick runs while one is open), and
// they act through the same worldstate verbs the natives use.

import "core:fmt"
import "core:slice"
import imgui "../../vendor/odin-imgui"
import "../audio"
import "../formid"
import "../gamedb"
import "../input"
import "../script"
import "../worldstate"

// (hole inventory-screen :tags ui :sev gap) the inventory is an ImGui placeholder, not a real menu: category tabs, a name list and an item card with value, weight and effects; no icons or 3D preview.
// (hole magic-screen :tags ui :sev gap) the magic menu is an ImGui placeholder, not a real menu: school tabs, a spell list and a card with cost and effects; no favourites and no shouts.
// (hole skills-screen :tags ui :sev gap) the skills menu is an ImGui placeholder, not a real menu: skill numbers, XP and the level-up choice buttons; no perk tree or constellations, and perk points cannot be spent.
// (hole pause-menu :tags (ui save) :sev gap) the pause menu is an ImGui placeholder, not a real menu: journal, stats and system tabs, each a sidebar and a panel.
// (hole container-screen :tags ui :sev gap) the container menu is an ImGui placeholder, not a real menu: two lists with take and store buttons; no barter, and an owned item does not say Steal. Barter must refuse a Quest Object (worldstate.quest_object_kept) and a stolen stack unless the vendor fences (BypassVendorStolenCheck).

Menu :: enum u8 {
	None,
	Tween, // the Tab cross: skills, magic, items, map
	Inventory,
	Magic,
	Skills,
	Map,
	Container,
	Pause,
	Dialogue,
}

Menu_Kind :: struct {
	title:        cstring,
	action:       string, // the input action that toggles it; "" = opened by something else
	pauses_world: bool,
	sounds:       [2]string, // the UI sounds (SNDR editor ids) it opens and closes with
}

MENUS := [Menu]Menu_Kind {
	.None      = {},
	.Tween     = {"##tween", "Tween", true, {"UIMenuBladeOpenSD", "UIMenuBladeCloseSD"}},
	.Inventory = {"Items", "Inventory", true, {"UIInventoryOpenSD", "UIMenuBladeCloseSD"}},
	.Magic     = {"Magic", "Magic", true, {"UIMenuBladeOpenSD", "UIMenuBladeCloseSD"}},
	.Skills    = {"Skills", "Skills", true, {"UIMenuBladeOpenSD", "UIMenuBladeCloseSD"}},
	.Map       = {"Map", "", true, {"UIMenuBladeOpenSD", "UIMenuBladeCloseSD"}},
	.Container = {"Container", "", true, {}}, // opens and closes with the container's own sounds
	.Pause     = {"Paused", "", true, {"UIJournalOpen", "UIJournalClose"}},
	.Dialogue  = {"Dialogue", "", false, {}},
}

// TWEEN is the cross and the menus it opens: Tab closes any of them.
TWEEN :: bit_set[Menu]{.Tween, .Inventory, .Magic, .Skills, .Map}

// Pane is a list pane whose selected row lives in Game.menu_pick.
Pane :: enum u8 {
	List, // items or spells
	Journal,
	Stats,
	System,
}

Quit_To :: enum u8 {
	Stay,
	Desktop,
	Main_Menu,
}

// world_paused reports whether an open menu stops the ticks.
world_paused :: proc(g: ^Game) -> bool {
	return MENUS[g.menu].pauses_world
}

// open_container shows a container's contents to the player (Activate on a container).
open_container :: proc(g: ^Game, container: Form_ID) {
	g.menu, g.menu_target = .Container, container
}

// (hole menu-park :tags (threading ui) :sev gap :needs (sim-drain)) a pausing menu only stops the accumulator, and its actions (equip, drink, drop, move_items, level_up, read_book) touch worldstate and the VM from ImGui code. Wanted: opening a pausing menu parks the sim, so the actions run with main as the owner.
// frame_menus toggles the menus from their actions and draws the open one. Runs after the script
// phase has joined, so worldstate is the main thread's.
frame_menus :: proc(g: ^Game) {
	was := g.menu
	defer if g.menu != was {
		audio.ui_sound(&g.audio, &g.v, &g.db, MENUS[was].sounds[1])
		audio.ui_sound(&g.audio, &g.v, &g.db, MENUS[g.menu].sounds[0])
		if was == .Container {audio.activate_sound(&g.audio, &g.v, &g.db, &g.ws, g.menu_target, done = true)}
	}
	for kind, m in MENUS {
		if kind.action == "" || !input.fired(&g.imgr, kind.action) {continue}
		closes := g.menu == m || (m == .Tween && g.menu in TWEEN)
		g.menu = .None if closes else m
	}
	if input.fired(&g.imgr, "Pause") {
		switch g.menu {
		case .None:     g.menu = .Pause
		case .Dialogue: back_out(g)
		case .Tween, .Inventory, .Magic, .Skills, .Map, .Container, .Pause: g.menu = .None // Esc closes any menu
		}
	}
	if g.menu == .None {return}
	if g.menu == .Tween {
		tween_menu(g)
		return
	}
	open := true
	imgui.SetNextWindowPos(imgui.Viewport_GetCenter(imgui.GetMainViewport()), .Appearing, {0.5, 0.5})
	imgui.SetNextWindowSize({760, 520}, .FirstUseEver)
	if imgui.Begin(MENUS[g.menu].title, &open) {
		switch g.menu {
		case .Inventory: inventory_menu(g)
		case .Magic:     magic_menu(g)
		case .Skills:    skills_menu(g)
		case .Map:       map_menu(g)
		case .Container: container_menu(g)
		case .Pause:     pause_menu(g)
		case .Dialogue:  dialogue_menu(g)
		case .None, .Tween:
		}
	}
	imgui.End()
	if !open {
		if g.menu == .Dialogue {back_out(g)} else {g.menu = .None}
	}
}

// tween_menu is the cross: skills on top, magic left, items right, map below.
@(private = "file")
tween_menu :: proc(g: ^Game) {
	CROSS :: [3][3]Menu{{.None, .Skills, .None}, {.Magic, .None, .Inventory}, {.None, .Map, .None}}
	SIZE :: imgui.Vec2{110, 60}
	imgui.SetNextWindowPos(imgui.Viewport_GetCenter(imgui.GetMainViewport()), .Always, {0.5, 0.5})
	if imgui.Begin(MENUS[.Tween].title, nil, {.NoTitleBar, .NoResize, .NoMove, .AlwaysAutoResize}) {
		for row in CROSS {
			for m, i in row {
				if i > 0 {imgui.SameLine()}
				if m == .None {
					imgui.Dummy(SIZE)
				} else if imgui.Button(MENUS[m].title, SIZE) {
					g.menu = m
				}
			}
		}
	}
	imgui.End()
}

// begin_split draws `rows` as a sidebar and opens the panel beside it; end_split closes it.
@(private = "file")
begin_split :: proc(g: ^Game, pane: Pane, rows: []string) -> (picked: int, ok: bool) {
	pick := &g.menu_pick[pane]
	pick^ = clamp(pick^, 0, len(rows) - 1)
	imgui.BeginChild(fmt.ctprintf("##side%v", pane), {220, 0}, {.Borders})
	for row, i in rows {
		if imgui.Selectable(fmt.ctprintf("%s##%d", row, i), pick^ == i) {pick^ = i}
	}
	imgui.EndChild()
	imgui.SameLine()
	imgui.BeginChild(fmt.ctprintf("##panel%v", pane), {0, 0}, {.Borders})
	return pick^, len(rows) > 0
}

@(private = "file")
end_split :: proc() {
	imgui.EndChild()
}

// browse is the items and magic layout: category tabs, a name list and the card of the picked form.
// tab_of is the category of a form, 0 = All only, -1 = hidden.
@(private = "file")
browse :: proc(g: ^Game, tabs: []cstring, rows: []$T, tab_of: proc(g: ^Game, row: T) -> int, label_of: proc(g: ^Game, row: T) -> string, card: proc(g: ^Game, row: T)) {
	if !imgui.BeginTabBar("##tabs") {return}
	sorted := slice.clone(rows, context.temp_allocator)
	context.user_ptr = &Sort_By_Label(T){g, label_of}
	slice.sort_by(sorted, proc(a, b: T) -> bool {
		s := (^Sort_By_Label(T))(context.user_ptr)
		return s.label_of(s.g, a) < s.label_of(s.g, b)
	})
	for name, tab in tabs {
		if !imgui.BeginTabItem(name) {continue}
		shown := make([dynamic]T, context.temp_allocator)
		labels := make([dynamic]string, context.temp_allocator)
		for row in sorted {
			t := tab_of(g, row)
			if t < 0 || (tab > 0 && t != tab) {continue}
			append(&shown, row)
			append(&labels, label_of(g, row))
		}
		if i, ok := begin_split(g, .List, labels[:]); ok {card(g, shown[i])}
		end_split()
		imgui.EndTabItem()
	}
	imgui.EndTabBar()
}

@(private = "file")
Sort_By_Label :: struct($T: typeid) {
	g:        ^Game,
	label_of: proc(g: ^Game, row: T) -> string,
}

@(private = "file")
spell_label :: proc(g: ^Game, spell: Form_ID) -> string {
	return fmt.tprintf("%s%s", "* " if worldstate.is_equipped(&g.ws, &g.db, formid.PLAYER, spell) else "", label(g, spell))
}

// stack_label is an item row: worn, stolen, and how many.
@(private = "file")
stack_label :: proc(g: ^Game, s: worldstate.Item_Stack) -> string {
	worn := "* " if !s.stolen && worldstate.is_equipped(&g.ws, &g.db, formid.PLAYER, s.item) else ""
	stolen := " (stolen)" if s.stolen else ""
	if s.count > 1 {return fmt.tprintf("%s%s%s (%d)", worn, label(g, s.item), stolen, s.count)}
	return fmt.tprintf("%s%s%s", worn, label(g, s.item), stolen)
}

// (hole item-categories :tags ui :sev polish) food sits under Potions and keys under Misc: the ALCH food flag and KEYM are not classified.
ITEM_TABS := [?]cstring{"All", "Weapons", "Apparel", "Potions", "Scrolls", "Ingredients", "Books", "Misc"}

@(private = "file")
item_tab :: proc(g: ^Game, s: worldstate.Item_Stack) -> int {
	item := s.item
	if item in g.db.books {return 6}
	#partial switch gamedb.form_kind(&g.db, item) {
	case .Weapon:     return 1
	case .Armor:      return 2
	case .Potion:     return 3
	case .Scroll:     return 4
	case .Ingredient: return 5
	}
	return 7
}

@(private = "file")
inventory_menu :: proc(g: ^Game) {
	browse(g, ITEM_TABS[:], worldstate.inv_stacks(&g.ws, &g.db, formid.PLAYER), item_tab, stack_label, item_card)
}

// (hole item-card-stats :tags ui :sev gap) the item card shows no damage or armor rating: WEAP DATA and ARMO DNAM are not decoded.
@(private = "file")
item_card :: proc(g: ^Game, s: worldstate.Item_Stack) {
	ws, db, item := &g.ws, &g.db, s.item
	c := script.Call{ws = ws, db = db}
	imgui.SeparatorText(fmt.ctprintf("%s%s", label(g, item), " (stolen)" if s.stolen else ""))
	imgui.TextUnformatted(fmt.ctprintf("Count  %d", s.count))
	if v, ok := gamedb.value_of(db, item); ok {imgui.TextUnformatted(fmt.ctprintf("Value  %d", v))}
	if w, ok := gamedb.weight_of(db, item); ok {imgui.TextUnformatted(fmt.ctprintf("Weight %.1f", w))}
	effect_lines(g, gamedb.effect_items_of(db, item))
	if slot, ok := gamedb.equip_slot_of(db, item); ok {effect_lines(g, gamedb.effect_items_of(db, slot.enchantment))}
	imgui.Spacing()
	switch {
	case item in db.books:
		if imgui.Button("Read") && read_book(g, script.item_stack(&c, formid.PLAYER, item), item) {
			script.move_items(&c, {base = item, from = formid.PLAYER, count = 1}) // a learned tome is used up
		}
	case is_drink(db, item):
		if imgui.Button("Use") {script.drink(&c, formid.PLAYER, item)}
	case:
		equip_buttons(g, item)
	}
	imgui.SameLine()
	if worldstate.quest_object_kept(ws, db, formid.PLAYER, item) {
		imgui.TextDisabled("Quest item")
	} else if imgui.Button("Drop") {
		script.drop_object(&c, formid.PLAYER, item, 0, 1, s.stolen)
	}
}

@(private = "file")
is_drink :: proc(db: ^gamedb.DB, item: Form_ID) -> bool {
	p, ok := gamedb.potion_of(db, item)
	return ok && !p.poison
}

// equip_buttons equips or unequips an item or a spell: one button per hand for an either-hand form.
@(private = "file")
equip_buttons :: proc(g: ^Game, form: Form_ID) {
	ws, db := &g.ws, &g.db
	if _, equips := gamedb.equip_slot_of(db, form); !equips {return}
	if worldstate.is_equipped(ws, db, formid.PLAYER, form) {
		if imgui.Button("Unequip") {worldstate.unequip(ws, db, formid.PLAYER, form)}
		return
	}
	if _, either := gamedb.slots_of(db, form); !either {
		if imgui.Button("Equip") {worldstate.equip(ws, db, formid.PLAYER, form)}
		return
	}
	if imgui.Button("Left hand") {worldstate.equip(ws, db, formid.PLAYER, form, gamedb.Slot.LeftHand)}
	imgui.SameLine()
	if imgui.Button("Right hand") {worldstate.equip(ws, db, formid.PLAYER, form, gamedb.Slot.RightHand)}
}

// (hole effect-text :tags (ui magic) :sev polish) effect descriptions show the raw <mag> and <dur> tokens, not the numbers.
@(private = "file")
effect_lines :: proc(g: ^Game, effects: []gamedb.Magic_Effect_Ref) {
	for e in effects {
		m, ok := gamedb.magic_effect_of(&g.db, e.effect)
		if !ok {continue}
		text := m.description if m.description != "" else label(g, e.effect)
		imgui.TextWrapped("%s", fmt.ctprintf("%s", text))
	}
}

MAGIC_TABS := [?]cstring{"All", "Alteration", "Conjuration", "Destruction", "Illusion", "Restoration", "Powers"}

@(private = "file")
magic_tab :: proc(g: ^Game, spell: Form_ID) -> int {
	sp, ok := gamedb.spell_of(&g.db, spell)
	if !ok {return -1}
	#partial switch sp.info.type {
	case .Power, .Lesser_Power, .Voice: return len(MAGIC_TABS) - 1
	case .Spell:
	case: return -1 // abilities, diseases and the like are not cast
	}
	i := gamedb.spell_costliest_effect(&g.db, spell) or_else -1
	if i < 0 {return 0}
	m, _ := gamedb.magic_effect_of(&g.db, sp.effects[i].effect)
	if m.info.magic_skill < 0 || int(m.info.magic_skill) >= len(gamedb.AV_NAMES) {return 0}
	for tab, t in MAGIC_TABS {
		if string(tab) == gamedb.AV_NAMES[m.info.magic_skill] {return t}
	}
	return 0
}

@(private = "file")
magic_menu :: proc(g: ^Game) {
	ws, db := &g.ws, &g.db
	for slot in ([]gamedb.Slot{.LeftHand, .RightHand, .Voice}) {
		imgui.TextUnformatted(fmt.ctprintf("%v: %s", slot, label(g, worldstate.in_slot(ws, db, formid.PLAYER, slot))))
		imgui.SameLine(0, 24)
	}
	imgui.NewLine()
	browse(g, MAGIC_TABS[:], worldstate.spell_list(ws, db, formid.PLAYER), magic_tab, spell_label, spell_card)
}

// (hole spell-cost :tags (ui magic) :sev polish) the spell card shows the SPIT base cost, not the cost after skill and perks.
@(private = "file")
spell_card :: proc(g: ^Game, spell: Form_ID) {
	sp, _ := gamedb.spell_of(&g.db, spell)
	imgui.SeparatorText(fmt.ctprintf("%s", label(g, spell)))
	imgui.TextUnformatted(fmt.ctprintf("Cost  %d", sp.info.cost))
	effect_lines(g, sp.effects)
	imgui.Spacing()
	equip_buttons(g, spell)
}

@(private = "file")
skills_menu :: proc(g: ^Game) {
	ws, db := &g.ws, &g.db
	s := ws.levels[formid.PLAYER]
	cost := worldstate.level_up_cost(ws, db, formid.PLAYER)
	imgui.TextUnformatted(fmt.ctprintf("Level %d   XP %.0f / %.0f   perk points %d", worldstate.actor_level(ws, db, formid.PLAYER), s.xp, cost, s.perk_points))
	if s.xp >= cost {
		imgui.TextUnformatted("Level up: choose")
		choices := make([dynamic]string, context.temp_allocator)
		for name in ws.level_choices {append(&choices, name)}
		slice.sort(choices[:])
		for name in choices {
			imgui.SameLine()
			if imgui.Button(fmt.ctprintf("%s", name)) {worldstate.level_up(ws, db, formid.PLAYER, name)}
		}
	}
	imgui.Separator()
	for skill, i in gamedb.AV_NAMES[6:24] {
		level := worldstate.av_current(ws, db, formid.PLAYER, skill)
		cap := worldstate.av_train_cap(ws, db, formid.PLAYER, skill)
		advance, _ := gamedb.skill_advance_av(skill)
		xp := worldstate.av_current(ws, db, formid.PLAYER, advance)
		next, open := worldstate.skill_level_cost(ws, db, formid.PLAYER, skill)
		if open {
			imgui.TextUnformatted(fmt.ctprintf("%-12s %3.0f / %3.0f   XP %.0f / %.0f", skill, level, cap, xp, next))
		} else {
			imgui.TextUnformatted(fmt.ctprintf("%-12s %3.0f / %3.0f", skill, level, cap))
			imgui.SameLine()
			if imgui.SmallButton(fmt.ctprintf("Legendary##%s", skill)) {
				c := script.Call{ws = ws, db = db}
				if worldstate.make_legendary(ws, db, formid.PLAYER, skill) {script.sync_constant_effects(&c, formid.PLAYER)}
			}
		}
		if s.legendary[i] > 0 {
			imgui.SameLine()
			imgui.TextUnformatted(fmt.ctprintf("legendary x%d", s.legendary[i]))
		}
	}
}

// (hole map-screen :tags ui :sev gap) no map — no world map, no local map, no fast-travel target.
@(private = "file")
map_menu :: proc(g: ^Game) {
	imgui.TextDisabled("No map yet.")
}

@(private = "file")
container_menu :: proc(g: ^Game) {
	c := script.Call{ws = &g.ws, db = &g.db}
	box := g.menu_target
	via := worldstate.Item_Via.Dead_Body if worldstate.is_dead(&g.ws, &g.db, box) else .Container
	imgui.TextUnformatted(fmt.ctprintf("%s", label(g, box)))
	for s in stacks_by_name(g, worldstate.inv_stacks(&g.ws, &g.db, box)) {
		imgui.TextUnformatted(fmt.ctprintf("%s  x%d", stack_label(g, {s.item, s.stolen, 1}), s.count))
		imgui.SameLine()
		if imgui.SmallButton(fmt.ctprintf("Take##%x%v", s.item, s.stolen)) {
			victim := script.report_theft(&c, formid.PLAYER, box, s.item, s.count)
			script.move_items(&c, {base = s.item, from = box, to = formid.PLAYER, count = s.count, via = .Steal if victim != 0 else via, stolen = s.stolen})
			if !s.stolen {worldstate.mark_stolen(&g.ws, &g.db, formid.PLAYER, s.item, victim, s.count)}
		}
	}
	imgui.Separator()
	imgui.TextUnformatted("Carried")
	for s in stacks_by_name(g, worldstate.inv_stacks(&g.ws, &g.db, formid.PLAYER)) {
		if !s.stolen && worldstate.is_equipped(&g.ws, &g.db, formid.PLAYER, s.item) || worldstate.quest_object_kept(&g.ws, &g.db, formid.PLAYER, s.item, box) {continue}
		imgui.TextUnformatted(fmt.ctprintf("%s  x%d", stack_label(g, {s.item, s.stolen, 1}), s.count))
		imgui.SameLine()
		if imgui.SmallButton(fmt.ctprintf("Store##%x%v", s.item, s.stolen)) {script.move_items(&c, {base = s.item, from = formid.PLAYER, to = box, count = s.count, via = via, stolen = s.stolen})}
	}
}

// stacks_by_name sorts item stacks by their items' names, a stolen stack after its clean one.
@(private = "file")
stacks_by_name :: proc(g: ^Game, stacks: []worldstate.Item_Stack) -> []worldstate.Item_Stack {
	out := slice.clone(stacks, context.temp_allocator)
	context.user_ptr = g
	slice.stable_sort_by(out, proc(a, b: worldstate.Item_Stack) -> bool {
		g := (^Game)(context.user_ptr)
		return label(g, a.item) < label(g, b.item)
	})
	return out
}

@(private = "file")
pause_menu :: proc(g: ^Game) {
	if !imgui.BeginTabBar("##pause") {return}
	if imgui.BeginTabItem("Journal") {
		journal_tab(g)
		imgui.EndTabItem()
	}
	if imgui.BeginTabItem("Stats") {
		stats_tab(g)
		imgui.EndTabItem()
	}
	if imgui.BeginTabItem("System") {
		system_tab(g)
		imgui.EndTabItem()
	}
	imgui.EndTabBar()
}

// (hole journal :tags (ui quest) :sev gap) the journal lists running quests with a logged stage, but no quest types, no completed-quests list and no objectives; stages show in index order, not the order they were reached.
@(private = "file")
journal_tab :: proc(g: ^Game) {
	quests := make([dynamic]Form_ID, context.temp_allocator)
	for quest in g.ws.quests {
		if in_journal(g, quest) {append(&quests, quest)}
	}
	sorted := by_name(g, quests[:])
	rows := make([]string, len(sorted), context.temp_allocator)
	for q, i in sorted {rows[i] = label(g, q)}
	if i, ok := begin_split(g, .Journal, rows); ok {quest_panel(g, sorted[i])}
	end_split()
}

// in_journal: the quest runs, is not complete, and has reached a stage with a log entry.
@(private = "file")
in_journal :: proc(g: ^Game, quest: Form_ID) -> bool {
	if !worldstate.quest_running(&g.ws, &g.db, quest) || worldstate.quest_completed(&g.ws, &g.db, quest) {return false}
	_, logged := current_log(g, quest)
	return logged
}

// current_log is the log entry of the highest done stage that has one.
@(private = "file")
current_log :: proc(g: ^Game, quest: Form_ID) -> (text: string, ok: bool) {
	q := worldstate.quest_get(&g.ws, quest) or_return
	best := -1
	for stage in q.done {
		if s, has := gamedb.quest_stage_log(&g.db, quest, stage); has && int(stage) > best {
			best, text, ok = int(stage), s, true
		}
	}
	return
}

@(private = "file")
quest_panel :: proc(g: ^Game, quest: Form_ID) {
	imgui.SeparatorText(fmt.ctprintf("%s", label(g, quest)))
	text, _ := current_log(g, quest)
	imgui.TextWrapped("%s", fmt.ctprintf("%s", text))
	imgui.Spacing()
	imgui.SeparatorText("Stages")
	qb, _ := gamedb.quest_baseline_of(&g.db, quest)
	stages := make([dynamic]u16, context.temp_allocator)
	for stage in qb.stage_log {append(&stages, stage)}
	slice.sort(stages[:])
	for stage in stages {
		done := worldstate.quest_is_stage_done(&g.ws, quest, stage)
		imgui.BeginDisabled()
		imgui.Checkbox(fmt.ctprintf("##stage%d", stage), &done)
		imgui.EndDisabled()
		imgui.SameLine()
		imgui.TextWrapped("%s", fmt.ctprintf("%d  %s", stage, qb.stage_log[stage]))
	}
}

STAT_CATEGORIES := [?]string{"General", "Quest", "Combat", "Magic", "Crafting", "Crime"}

// (hole stats-screen :tags ui :sev gap) the stats tab lists the categories only: Skyrim's MiscStat counters (days passed, locks picked, bounty) are not tracked.
@(private = "file")
stats_tab :: proc(g: ^Game) {
	if _, ok := begin_split(g, .Stats, STAT_CATEGORIES[:]); ok {imgui.TextDisabled("No stats are tracked yet.")}
	end_split()
}

System_Entry :: enum u8 {
	Quicksave,
	Save,
	Load,
	Settings,
	Mods,
	Quit,
}

SYSTEM_ROWS := [System_Entry]string {
	.Quicksave = "Quicksave",
	.Save      = "Save",
	.Load      = "Load",
	.Settings  = "Settings",
	.Mods      = "Mod settings",
	.Quit      = "Quit",
}

// (hole save-screen :tags (ui save) :sev gap :needs save-slots) Save and Load show only the one quicksave: there is no list of named saves.
// (hole settings-screen :tags ui :sev gap) the Settings panel is empty: settings.txt is edited by hand.
// (hole mod-config-screen :tags (ui mods) :sev gap) the mod settings panel is empty: mods have no configuration menus.
@(private = "file")
system_tab :: proc(g: ^Game) {
	rows := SYSTEM_ROWS
	i, _ := begin_split(g, .System, slice.enumerated_array(&rows))
	switch System_Entry(i) {
	case .Quicksave:
		if imgui.Button("Quicksave now") {quicksave(g)}
	case .Save:
		imgui.TextDisabled("No save slots yet. Use Quicksave.")
	case .Load:
		if imgui.Button("Load quicksave") {
			g.menu = .None
			quickload(g)
		}
	case .Settings:
		imgui.TextDisabled("No settings menu yet.")
	case .Mods:
		imgui.TextDisabled("No mod settings yet.")
	case .Quit:
		imgui.TextUnformatted("Quit to:")
		if imgui.Button("Main menu") {g.quit = .Main_Menu}
		imgui.SameLine()
		if imgui.Button("Desktop") {g.quit = .Desktop}
	}
	end_split()
}

@(private = "file")
label :: proc(g: ^Game, form: Form_ID) -> string {
	if form == 0 {return "-"}
	if name := gamedb.name_of(&g.db, form); name != "" {return name}
	return fmt.tprintf("0x%08X", form)
}

// by_name is `forms` sorted by their names, for a stable list.
@(private = "file")
by_name :: proc(g: ^Game, forms: []Form_ID) -> []Form_ID {
	out := slice.clone(forms, context.temp_allocator)
	context.user_ptr = g
	slice.sort_by(out, proc(a, b: Form_ID) -> bool {
		g := (^Game)(context.user_ptr)
		return label(g, a) < label(g, b)
	})
	return out
}
