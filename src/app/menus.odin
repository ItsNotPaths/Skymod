package main

// Placeholder menus: Dear ImGui windows standing in for the player's screens until the Lua UI has
// them (ui/source.odin). Like Skyrim's, they pause the world (no tick runs while one is open), and
// they act through the same worldstate verbs the natives use.

import "core:fmt"
import "core:slice"
import imgui "../../vendor/odin-imgui"
import "../formid"
import "../gamedb"
import "../input"
import "../script"
import "../worldstate"

// (hole inventory-screen :tags ui :sev gap) the inventory is an ImGui placeholder, not a real menu: a name list with equip, drop and Use (potions) buttons; no categories, icons, item card or 3D preview.
// (hole magic-screen :tags ui :sev gap) the magic menu is an ImGui placeholder, not a real menu: a flat spell list with hand buttons; no schools, effect text or favourites, and no way to equip a power or shout.
// (hole skills-screen :tags ui :sev gap) the skills menu is an ImGui placeholder, not a real menu: skill numbers, XP and the level-up choice buttons; no perk tree or constellations, and perk points cannot be spent.
// (hole pause-menu :tags (ui save) :sev gap) the pause menu is an ImGui placeholder, not a real menu: Resume and Quit; no save and load lists, settings or help.
// (hole container-screen :tags ui :sev gap) the container menu is an ImGui placeholder, not a real menu: two lists with take and store buttons; no barter, stealing or ownership.

Menu :: enum u8 {
	None,
	Inventory,
	Magic,
	Skills,
	Container,
	Pause,
	Dialogue,
}

Menu_Kind :: struct {
	title:        cstring,
	action:       string, // the input action that toggles it; "" = opened by something else
	pauses_world: bool,
}

MENUS := [Menu]Menu_Kind {
	.None      = {},
	.Inventory = {"Inventory (placeholder)", "Inventory", true},
	.Magic     = {"Magic (placeholder)", "Magic", true},
	.Skills    = {"Skills (placeholder)", "Skills", true},
	.Container = {"Container (placeholder)", "", true},
	.Pause     = {"Paused (placeholder)", "", true},
	.Dialogue  = {"Dialogue (placeholder)", "", false},
}

// world_paused reports whether an open menu stops the ticks.
world_paused :: proc(g: ^Game) -> bool {
	return MENUS[g.menu].pauses_world
}

// open_container shows a container's contents to the player (Activate on a container).
open_container :: proc(g: ^Game, container: Form_ID) {
	g.menu, g.menu_target = .Container, container
}

// frame_menus toggles the menus from their actions and draws the open one. Runs after the script
// phase has joined, so worldstate is the main thread's.
frame_menus :: proc(g: ^Game) {
	for kind, m in MENUS {
		if kind.action != "" && input.fired(&g.imgr, kind.action) {g.menu = .None if g.menu == m else m}
	}
	if input.fired(&g.imgr, "Pause") {
		switch g.menu {
		case .None:     g.menu = .Pause
		case .Dialogue: back_out(g)
		case .Inventory, .Magic, .Skills, .Container, .Pause: g.menu = .None // Esc closes any menu
		}
	}
	if g.menu == .None {return}
	open := true
	imgui.SetNextWindowSize({520, 560}, .FirstUseEver)
	if imgui.Begin(MENUS[g.menu].title, &open) {
		switch g.menu {
		case .Inventory: inventory_menu(g)
		case .Magic:     magic_menu(g)
		case .Skills:    skills_menu(g)
		case .Container: container_menu(g)
		case .Pause:     pause_menu(g)
		case .Dialogue:  dialogue_menu(g)
		case .None:
		}
	}
	imgui.End()
	if !open {
		if g.menu == .Dialogue {back_out(g)} else {g.menu = .None}
	}
}

@(private = "file")
inventory_menu :: proc(g: ^Game) {
	ws, db := &g.ws, &g.db
	c := script.Call{ws = ws, db = db}
	for item in by_name(g, worldstate.inv_items(ws, db, formid.PLAYER)) {
		worn := worldstate.is_equipped(ws, db, formid.PLAYER, item)
		imgui.TextUnformatted(fmt.ctprintf("%s%s  x%d", "* " if worn else "", label(g, item), worldstate.inv_count(ws, db, formid.PLAYER, item)))
		imgui.SameLine()
		if imgui.SmallButton(fmt.ctprintf("Drop##%x", item)) {script.drop_object(&c, formid.PLAYER, item, 0, 1)}
		if item in db.books {
			imgui.SameLine()
			if imgui.SmallButton(fmt.ctprintf("Read##%x", item)) && worldstate.read_book(ws, db, formid.PLAYER, item) {
				script.move_items(&c, {base = item, from = formid.PLAYER, count = 1}) // a learned tome is used up
			}
			continue
		}
		if p, potion := gamedb.potion_of(db, item); potion && !p.poison {
			imgui.SameLine()
			if imgui.SmallButton(fmt.ctprintf("Use##%x", item)) {script.drink(&c, formid.PLAYER, item)}
			continue
		}
		if _, equips := gamedb.equip_slot_of(db, item); !equips {continue}
		if _, either := gamedb.slots_of(db, item); either && !worn {
			for hand in ([]gamedb.Slot{.LeftHand, .RightHand}) {
				imgui.SameLine()
				if imgui.SmallButton(fmt.ctprintf("%v##%x", hand, item)) {worldstate.equip(ws, db, formid.PLAYER, item, hand)}
			}
			continue
		}
		imgui.SameLine()
		if imgui.SmallButton(fmt.ctprintf("%s##%x", "Unequip" if worn else "Equip", item)) {
			if worn {worldstate.unequip(ws, db, formid.PLAYER, item)} else {worldstate.equip(ws, db, formid.PLAYER, item)}
		}
	}
}

@(private = "file")
magic_menu :: proc(g: ^Game) {
	ws, db := &g.ws, &g.db
	for slot in ([]gamedb.Slot{.LeftHand, .RightHand, .Voice}) {
		imgui.TextUnformatted(fmt.ctprintf("%v: %s", slot, label(g, worldstate.in_slot(ws, db, formid.PLAYER, slot))))
	}
	imgui.Separator()
	for spell in by_name(g, worldstate.spell_list(ws, db, formid.PLAYER)) {
		imgui.TextUnformatted(fmt.ctprintf("%s", label(g, spell)))
		for slot in ([]gamedb.Slot{.LeftHand, .RightHand}) {
			imgui.SameLine()
			if imgui.SmallButton(fmt.ctprintf("%v##%x", slot, spell)) {worldstate.equip(ws, db, formid.PLAYER, spell, slot)}
		}
	}
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

@(private = "file")
container_menu :: proc(g: ^Game) {
	c := script.Call{ws = &g.ws, db = &g.db}
	box := g.menu_target
	via := worldstate.Item_Via.Dead_Body if worldstate.is_dead(&g.ws, box) else .Container
	imgui.TextUnformatted(fmt.ctprintf("%s", label(g, box)))
	for item in by_name(g, worldstate.inv_items(&g.ws, &g.db, box)) {
		n := worldstate.inv_count(&g.ws, &g.db, box, item)
		imgui.TextUnformatted(fmt.ctprintf("%s  x%d", label(g, item), n))
		imgui.SameLine()
		if imgui.SmallButton(fmt.ctprintf("Take##%x", item)) {script.move_items(&c, {base = item, from = box, to = formid.PLAYER, count = n, via = via})}
	}
	imgui.Separator()
	imgui.TextUnformatted("Carried")
	for item in by_name(g, worldstate.inv_items(&g.ws, &g.db, formid.PLAYER)) {
		if worldstate.is_equipped(&g.ws, &g.db, formid.PLAYER, item) {continue}
		n := worldstate.inv_count(&g.ws, &g.db, formid.PLAYER, item)
		imgui.TextUnformatted(fmt.ctprintf("%s  x%d", label(g, item), n))
		imgui.SameLine()
		if imgui.SmallButton(fmt.ctprintf("Store##%x", item)) {script.move_items(&c, {base = item, from = formid.PLAYER, to = box, count = n, via = via})}
	}
}

@(private = "file")
pause_menu :: proc(g: ^Game) {
	if imgui.Button("Resume") {g.menu = .None}
	if imgui.Button("Quit") {g.quit = true}
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
