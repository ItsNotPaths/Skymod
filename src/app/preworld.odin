package main

// The PRE-WORLD boot screens: Main Menu ⇆ Mod Manager, shown BEFORE the world builds. This is the
// one place the two UI worlds meet — the Lua menu (run_lua_main_menu, the moddable skinned UI) and
// the imgui mod manager (run_mod_manager, engine-compiled and therefore unbreakable by mods). The
// manager edits the profile here, so the world mount/load after us builds from the FINAL profile —
// enabling a mod and entering the world is seamless (no relaunch). The menu is re-run (fresh VFS +
// atlas + VM) after every manager visit, so a profile switch/apply is reflected immediately: the
// menu is a pure function of the active profile.

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "../mods"
import "../platform"
import "../render"
import "../settings"
import "../tools"
import "../worldstate"

// Boot_Choice is the pre-world phase's outcome: what the player picked in the menu (or Quit for a
// closed window).
Boot_Choice :: enum {
	Quit,
	New,
	Continue,
}

// run_preworld pumps Main Menu ⇆ Mod Manager until the player commits to entering the world (New /
// Continue) or quits. `--skipmenu` (dev) jumps straight to a new game.
run_preworld :: proc(
	p: ^platform.Platform,
	r: ^render.Renderer,
	base, src: string,
	profile: ^mods.Profile,
	cfg: ^settings.Config,
	quicksave_path: string,
) -> Boot_Choice {
	if slice.contains(os.args, "--skipmenu") {
		return .New // dev: jump straight to a new game, skipping the boot menu
	}
	// save_summary is OWNED (not temp): the imgui fallback menu re-reads it every frame across its
	// per-frame free_all(temp), so a tprintf here would dangle after the first frame.
	save_summary: string
	defer delete(save_summary)
	has_save := false
	if man, ok := worldstate.read_manifest(quicksave_path); ok {
		has_save = true
		save_summary = fmt.aprintf("Save %d — %d change(s)", man.save_number, man.delta_count)
	}
	for {
		switch run_main_menu(p, r, base, src, profile, has_save, save_summary) {
		case .Mods:
			if !run_mod_manager(p, r, profile, src, base, cfg) {
				return .Quit // window closed inside the mod manager
			}
			continue // Back → re-run the menu against the (possibly changed) profile
		case .Continue:
			return .Continue
		case .New:
			return .New
		case .None, .Quit:
			return .Quit // window closed or Quit
		}
	}
}

// run_main_menu pumps the boot main menu until the player picks an action — or the window closes,
// reported as .None (the caller treats None/Quit alike: exit). It first tries the synthesized
// built-in Lua menu (real Skyrim font via the SDL3_gpu UI path, run_lua_main_menu); if that can't
// initialize (no font in the install / load error), it falls back to the imgui boot menu so the
// engine never bricks. A pre-world modal screen: clears the frame behind the UI, no world/streaming.
@(private = "file")
run_main_menu :: proc(
	p: ^platform.Platform,
	r: ^render.Renderer,
	base, src: string,
	profile: ^mods.Profile,
	has_save: bool,
	save_summary: string,
) -> tools.Menu_Action {
	if action, ok := run_lua_main_menu(p, r, base, src, profile); ok {
		return action
	}
	log.warn("menu: built-in Lua UI unavailable; using the imgui boot menu")
	choice := tools.Menu_Action.None
	for choice == .None && platform.pump(p) {
		render.ui_new_frame(r)
		choice = tools.main_menu_screen(has_save, save_summary)
		if render.begin_frame(r, {0.05, 0.06, 0.08, 1.0}) {
			render.end_frame(r)
		}
		free_all(context.temp_allocator)
	}
	return choice
}
