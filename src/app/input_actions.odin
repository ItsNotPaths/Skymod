package main

// The default control scheme + settings glue for the input substrate (src/input).
// This is where the engine's built-in actions are declared and where per-binding
// overrides are read from / written to settings.txt (`bind.<Action> = <gesture>`).
// A mod adds its own actions at load via input.register — it does not edit this list.
//
// Migration status (input wave): discrete verbs run through the manager now; analog
// movement/look + the held modifiers (sprint/hover) + mouse-select still read the
// legacy platform.Input snapshot and move over as the axis/look path lands.

import "core:fmt"
import "../input"
import "../settings"

Default_Action :: struct {
	id:   string,
	ctx:  string,
	kind: input.Action_Kind,
	bind: string,
}

// The built-in scheme. `ctx` "global" = live even while a menu/overlay owns input;
// "gameplay" = suppressed when the UI captures the keyboard; "menu" = suppressed only while a text
// field is typed in, so a menu's own key closes it. Bindings are the DEFAULTS;
// a per-profile settings.txt `bind.<id>` line overrides any of them.
DEFAULT_ACTIONS := [?]Default_Action {
	{"Activate",      "gameplay", .Button, "e"},
	{"CastLeft",      "gameplay", .Button, "mouse1"},
	{"CastRight",     "gameplay", .Button, "mouse2"},
	{"Sneak",         "gameplay", .Button, "lctrl"},
	{"ToggleOverlay", "global",   .Button, "grave"},
	{"ToggleProfiler", "global",  .Button, "f3"},
	{"NoClip",        "gameplay", .Button, "v"},
	{"QuickSave",     "gameplay", .Button, "f5"},
	{"QuickLoad",     "gameplay", .Button, "f9"},
	// placeholder menus (menus.odin)
	{"Pause",         "menu",     .Button, "esc"},
	{"Tween",         "menu",     .Button, "tab"},
	{"Inventory",     "menu",     .Button, "i"},
	{"Magic",         "menu",     .Button, "p"},
	{"Skills",        "menu",     .Button, "l"},
	// dev-verification verbs (behind the dev overlay in practice)
	{"DevDrop",       "gameplay", .Button, "g"},
	{"DevShove",      "gameplay", .Button, "h"},
	{"DevHitbox",     "gameplay", .Button, "k"},
	{"DevDisable",    "gameplay", .Button, "x"},
	{"DevSpawn",      "gameplay", .Button, "b"},
	{"DevGrabActor",  "gameplay", .Button, "j"},
	{"DevShoot",      "gameplay", .Button, "mouse1"},
}

// input_setup initializes the manager, registers the default scheme, then applies any
// `bind.<id>` override found in cfg (a bad override is ignored; the default stands).
input_setup :: proc(m: ^input.Manager, cfg: ^settings.Config) {
	input.init(m)
	for d in DEFAULT_ACTIONS {
		input.register(m, d.id, d.ctx, d.kind, d.bind)
		key := fmt.tprintf("bind.%s", d.id)
		if ov := settings.get(cfg, key); ov != "" {
			if !input.rebind(m, d.id, ov) {
				fmt.eprintfln("input: ignoring bad binding %s = %q", key, ov)
			}
		}
	}
}

// input_save_bindings writes each REBOUND action back to cfg as `bind.<id>` (call after
// a rebind, before settings.save). Bindings still at their default are skipped so a
// profile overlay stays sparse — it records only the controls this profile changed.
// Used by the future rebind editor; kept here so the key convention lives in one place.
input_save_bindings :: proc(m: ^input.Manager, cfg: ^settings.Config) {
	for &a in m.actions {
		if a.bind_str == a.default_bind {
			continue
		}
		key := fmt.tprintf("bind.%s", a.id)
		settings.set(cfg, key, a.bind_str)
	}
}
