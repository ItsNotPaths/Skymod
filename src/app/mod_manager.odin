package main

// The mod-manager controller: pumps the imgui manager screen (tools.mod_manager_screen) and applies
// its result to the profile — toggles, drag-reorders, separators, profile switch/create, missing-
// master auto-disable. DELIBERATELY imgui, not Lua: it's a complex, engine-owned tool, and keeping
// it compiled means no mod content is ever on its code path — a broken UI mod can't take out the
// screen that disables it (the anti-softlock guarantee). Reached from the main menu via the "mods"
// verb; preworld.odin re-runs the Lua menu on return so profile changes show immediately.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../gamedb"
import "../mods"
import "../platform"
import "../render"
import "../settings"
import "../tools"

// run_mod_manager pumps the mod-manager screen until Back (→ true, return to the main menu)
// or the window closes (→ false, quit).
run_mod_manager :: proc(
	p: ^platform.Platform,
	r: ^render.Renderer,
	profile: ^mods.Profile,
	src, base: string,
	cfg: ^settings.Config,
) -> bool {
	new_seq := 0
	dirty := true // recompute the derived plugin order whenever the mod list changes
	derived: []Derived_Plugin
	missing: []gamedb.Missing_Master

	for platform.pump(p) {
		render.ui_new_frame(r)

		active := settings.get(cfg, "active_profile")
		if active == "" {
			active = DEFAULT_PROFILE
		}
		// vanilla is the immutable baseline: its plugin list is locked to the system mods,
		// so list-editing verbs are ignored while it's active (switch/create still work).
		locked_profile := strings.equal_fold(active, DEFAULT_PROFILE)
		if dirty {
			free_derived(derived)
			free_missing(missing)
			derived, missing = derive_plugin_order(src, base, profile)
			dirty = false
		}

		// Per-frame plain-data views for the imgui-core panel (temp; names borrowed).
		mods_view := make([]tools.Mod_Entry_View, len(profile.mods), context.temp_allocator)
		for m, i in profile.mods {
			mods_view[i] = {
				name      = m.name,
				enabled   = m.enabled,
				locked    = m.locked,
				separator = m.kind == .Separator,
			}
		}
		plugins_view := make([]tools.Plugin_Row_View, len(derived), context.temp_allocator)
		for d, i in derived {
			plugins_view[i] = {name = d.name, source = d.source, master = d.master}
		}
		missing_view := make([]tools.Missing_Master_View, len(missing), context.temp_allocator)
		for m, i in missing {
			missing_view[i] = {plugin = m.plugin, master = m.master}
		}
		profiles := discover_profiles(base, context.temp_allocator)

		// (hole save-orphan-cleanup :tags (mods save ui) :sev gap) no button cleans a save of what removed mods left in it: plugin blobs whose plugin is gone, and script state of scripts no mod ships any more (user 2026-09-28).
		res := tools.mod_manager_screen(profiles, active, mods_view, plugins_view, missing_view)

		// vanilla is the immutable baseline: drop any plugin-list edits (switch/create still apply).
		if locked_profile {
			res.toggled = -1
			res.move_from, res.move_to = -1, -1
			res.add_separator = false
			res.add_empty = false
			res.auto_disable_missing = false
		}

		if res.toggled >= 0 {mods.profile_toggle(profile, res.toggled);dirty = true}
		if res.move_from >= 0 && res.move_to >= 0 {
			mods.profile_move_to(profile, res.move_from, res.move_to)
			dirty = true
		}
		if res.add_separator {
			new_seq += 1
			mods.profile_add_separator(profile, fmt.tprintf("New Separator %d", new_seq))
			dirty = true
		}
		if res.add_empty {
			new_seq += 1
			name := fmt.tprintf("New Mod %d", new_seq)
			// Create the folder under <base>/mods so the empty mod persists + is discoverable.
			_ = os.make_directory(mods_root(base))
			dir, _ := filepath.join({mods_root(base), name}, context.temp_allocator)
			_ = os.make_directory(dir)
			mods.profile_add(profile, name)
			dirty = true
		}
		// Resolve missing masters by disabling each dependent plugin's providing mod (the constructive
		// half of the doc's "refuse or auto-disable" — the destructive silent cross-wire is already
		// killed in the resolver by INVALID_SLOT; this makes the load clean).
		if res.auto_disable_missing {
			for mm in missing {
				for d in derived {
					if strings.equal_fold(d.name, mm.plugin) {
						idx := mods.profile_index(profile, d.source)
						if idx >= 0 && profile.mods[idx].enabled {mods.profile_toggle(profile, idx)}
						break
					}
				}
			}
			dirty = true
		}

		// Profile switch: persist the current list, then load the target's (mods/ stays shared).
		if res.switch_profile >= 0 && res.switch_profile < len(profiles) {
			target := profiles[res.switch_profile]
			if !strings.equal_fold(target, active) {
				_ = mods.profile_save(profile, modlist_path_for(base, active))
				settings.set(settings.root(cfg), "active_profile", target) // root-only key
				_ = settings.save(settings.root(cfg))
				switch_profile(profile, src, base, target)
				dirty = true
			}
		}
		// New profile: a fresh list (all mods enabled by default), made active.
		if res.create_profile {
			name := fmt.tprintf("Profile %d", len(profiles))
			ensure_profile_dir(base, name)
			_ = mods.profile_save(profile, modlist_path_for(base, active))
			// New profile inherits the vanilla baseline automatically (empty settings overlay);
			// no values are copied — anything unset resolves through the root at load time.
			settings.set(settings.root(cfg), "active_profile", name) // root-only key
			_ = settings.save(settings.root(cfg))
			switch_profile(profile, src, base, name)
			dirty = true
		}

		if render.begin_frame(r, {0.05, 0.06, 0.08, 1.0}) {
			render.end_frame(r)
		}
		free_all(context.temp_allocator)

		if res.action == .Exit {
			if mods.profile_save(profile, modlist_path_for(base, active)) {
				log.infof("mods: saved profile %q — %d item(s)", active, len(profile.mods))
			}
			_ = settings.save(cfg)
			free_derived(derived)
			free_missing(missing)
			return true
		}
	}
	free_derived(derived)
	free_missing(missing)
	return false // window closed
}

// switch_profile reloads `profile` in place from <base>/modprofiles/<name>/modlist.txt, reconciled
// against the (shared) installed mod folders, then re-syncs the locked system rows (needs `src` for
// DLC detection).
@(private = "file")
switch_profile :: proc(profile: ^mods.Profile, src, base, name: string) {
	mods.profile_destroy(profile)
	mods.profile_init(profile)
	_ = mods.profile_load(profile, modlist_path_for(base, name))
	mods.profile_reconcile(profile, discover_mod_folders(base, context.temp_allocator))
	mods.profile_set_system(profile, system_mod_names(src, base))
}

// free_derived releases a derived-plugin slice (the names/sources are heap-owned).
@(private = "file")
free_derived :: proc(d: []Derived_Plugin) {
	for e in d {
		delete(e.name)
		delete(e.source)
	}
	delete(d)
}

// free_missing releases a missing-master slice (plugin/master strings are heap-owned).
@(private = "file")
free_missing :: proc(m: []gamedb.Missing_Master) {
	for e in m {
		delete(e.plugin)
		delete(e.master)
	}
	delete(m)
}
