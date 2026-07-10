package tools

// Dev tooling UI (ROADMAP Phase 0, step 6): Dear ImGui panels — the FPS/frame-time
// overlay and a stub Inspector, growing into asset browsers and the golden differ.
// This package uses only the imgui CORE API (no SDL, no SDL3_gpu): the backends and
// the frame lifecycle live in src/render. Build these widgets between
// render.ui_new_frame and render.begin_frame.

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "../lighting"
import smath "../math"
import imgui "../../vendor/odin-imgui"

// debug_overlay draws the Stats panel for `dt` (seconds of the last frame).
// `persisting`/`persist_path` reflect the logger state (slog). `pretty` is the live
// render-toggle for hiding untextured marker placeholders (edited in place by the checkbox).
// Returns true on the frame the user clicks "Persist this run's log" so the caller can act.
debug_overlay :: proc(dt: f32, persisting: bool, persist_path: string, pretty: ^bool) -> (persist_clicked: bool) {
	io := imgui.GetIO()

	if imgui.Begin("Stats", nil, {.NoCollapse}) {
		imgui.TextUnformatted(fmt.ctprintf("%.1f FPS", io.Framerate))
		imgui.TextUnformatted(fmt.ctprintf("%.2f ms/frame", dt * 1000))
		imgui.Separator()
		imgui.Checkbox("pretty (hide CK debug shapes)", pretty)
		imgui.Separator()
		if persisting {
			imgui.TextUnformatted(fmt.ctprintf("Persisting log -> %s", filepath.base(persist_path)))
		} else if imgui.Button("Persist this run's log") {
			persist_clicked = true
		}
	}
	imgui.End()

	return
}

// stream_panel shows the exterior-streaming state (ROADMAP Section F): the player's
// current cell, how many chunks are loaded, and the worker's decode/upload backlog —
// so streaming progress is visible. All plain values (this package stays imgui-core).
stream_panel :: proc(gx, gy: i32, chunks, inflight, reqs, ready: int) {
	if imgui.Begin("Streaming", nil, {.NoCollapse}) {
		imgui.TextUnformatted(fmt.ctprintf("cell:      (%d, %d)", gx, gy))
		imgui.TextUnformatted(fmt.ctprintf("chunks:    %d loaded", chunks))
		imgui.TextUnformatted(fmt.ctprintf("decoding:  %d in flight", inflight))
		imgui.TextUnformatted(fmt.ctprintf("queue:     %d to decode / %d to upload", reqs, ready))
	}
	imgui.End()
}

// interiors_panel shows the open-interiors experiment's state (EXPERIMENTAL): how many
// interior-linked load doors were discovered (portals) and the nearest door's distance vs. the
// view threshold. `nearest` is max(f32) when there are no portals; pass the raw values from
// world.interiors_stats. Plain values only (this package stays imgui-core).
// Interior_Action is what the open-interiors panel requests this frame.
Interior_Action :: enum {
	None,
	Enter, // load fully INTO the active portal's interior cell (debug walk-in + picker)
	Exit,  // return to the exterior
}

// interiors_panel shows the experiment's state + live portal-camera tuning, and offers a
// debug "Load Into Cell" button (enabled when a portal is active) that swaps the camera +
// picker into the interior cell — and an "Exit Interior" button once inside. Returns the
// requested action. `can_enter` = a portal interior is loaded; `entered` = currently inside.
interiors_panel :: proc(
	portals: int,
	load_dist, nearest: f32,
	push, yaw_off: ^f32,
	can_enter, entered: bool,
) -> (action: Interior_Action) {
	if imgui.Begin("Open Interiors (experimental)", nil, {.NoCollapse}) {
		imgui.TextUnformatted(fmt.ctprintf("interiors linked: %d", portals))
		if nearest < max(f32) {
			imgui.TextUnformatted(fmt.ctprintf("nearest door: %.0f u  (view < %.0f)", nearest, load_dist))
		} else {
			imgui.TextUnformatted("nearest door: none")
		}
		if entered {
			imgui.TextUnformatted("INSIDE interior cell (picker active here)")
			if imgui.Button("Exit Interior") {
				action = .Exit
			}
		} else if can_enter {
			if imgui.Button("Load Into Cell") {
				action = .Enter
			}
		} else {
			imgui.TextUnformatted("(no portal in range to enter)")
		}
		// Live portal-camera tuning: how far past the doorway plane the eye is clamped (clears
		// the entrance wall) and a yaw offset on the relayed look direction (facing fix).
		imgui.TextUnformatted("portal camera:")
		imgui.SliderFloat("depth past door (u)", push, -128, 512, "%.0f")
		imgui.SliderFloat("yaw (rad)", yaw_off, -3.14159, 3.14159, "%.2f")
		if imgui.Button("Reset") {
			push^, yaw_off^ = 32, 0
		}
	}
	imgui.End()
	return
}

// Inspector state shared with the app each frame: the click-picked model's info (for
// inspection). The app fills these before this panel runs. (Door activation moved to the
// crosshair — see the engine's frame_interact — so there's no proximity door prompt here.)
Inspector :: struct {
	// Click-picked model (info only):
	has_sel:        bool,
	sel_name:       string, // MODL mesh path of the picked instance
	sel_display:    string, // FULL display name (gamedb.name_of), "" if unnamed
	sel_base:       u64, // global Form_ID of the picked base (display only)
	sel_pos:        smath.Vec3,
	sel_rot:        smath.Vec3, // stored euler radians
	sel_has_door:   bool,
	sel_door_cell:  string,
	sel_tex:        string, // diffuse texture of the picked SHAPE ("" = none/white fallback)
	sel_is_door:    bool, // gamedb.is_door(base) at runtime — diagnostic for the portal door cull
}

// inspector_set_model_strings stores OWNED copies of the picked model's path + texture.
// They must not borrow from the cached Model: the selection can outlive the instance's
// chunk, and D1 cache eviction will free the model (and the strings inside it) while the
// panel still shows them. Frees the previous copies; inspector_destroy frees the last.
inspector_set_model_strings :: proc(insp: ^Inspector, name, tex: string) {
	delete(insp.sel_name)
	delete(insp.sel_tex)
	insp.sel_name = strings.clone(name)
	insp.sel_tex = strings.clone(tex)
}

inspector_destroy :: proc(insp: ^Inspector) {
	delete(insp.sel_name)
	delete(insp.sel_tex)
	insp.sel_name, insp.sel_tex = "", ""
}

// Inspect_Action is what the inspector panel requested this frame.
Inspect_Action :: enum {
	None,
	Cull_Tex, // add the picked shape's texture to the portal cull set
}

// inspector_panel shows the picked model's identity (ROADMAP Iteration 1, Milestone D).
// Left-click any model to inspect its MODL/base/pos/rotation. (Door crossing is on the
// crosshair now — look at a door and press Activate — so there's no door prompt here.)
inspector_panel :: proc(insp: ^Inspector) -> (action: Inspect_Action) {
	if imgui.Begin("Inspector", nil, {}) {
		if insp.has_sel {
			if insp.sel_display != "" {
				imgui.TextUnformatted(fmt.ctprintf("name:  %s", insp.sel_display))
			}
			imgui.TextUnformatted(fmt.ctprintf("model: %s", insp.sel_name))
			imgui.TextUnformatted(fmt.ctprintf("base:  0x%08X  is_door=%v", insp.sel_base, insp.sel_is_door))
			imgui.TextUnformatted(
				fmt.ctprintf("pos:   %.0f, %.0f, %.0f", insp.sel_pos.x, insp.sel_pos.y, insp.sel_pos.z),
			)
			r := insp.sel_rot * (180.0 / math.PI)
			imgui.TextUnformatted(fmt.ctprintf("rot:   %.1f, %.1f, %.1f deg", r.x, r.y, r.z))
			// The picked SHAPE's diffuse texture — the thing to identify for texture-based culling.
			tex := insp.sel_tex if insp.sel_tex != "" else "(none / white)"
			imgui.TextUnformatted(fmt.ctprintf("tex:   %s", tex))
			if insp.sel_has_door {
				name := insp.sel_door_cell if insp.sel_door_cell != "" else "(exterior)"
				imgui.TextUnformatted(fmt.ctprintf("load door → %s", name))
			}
			if insp.sel_tex != "" && imgui.Button("Cull this texture in portal") {
				action = .Cull_Tex
			}
		} else {
			imgui.TextUnformatted("Hold Ctrl to highlight the model under the cursor; click to inspect it.")
		}
	}
	imgui.End()
	return
}

// Console is the dev command console (a fixed panel docked bottom-left): an input box plus an
// owned scrollback of output lines. It's the seat for the command system to come — CE aliases
// (tcl, player.additem, …) over our own better semantics — but today it only echoes. Call
// console_init before use and console_destroy at shutdown (the scrollback is heap-owned).
Console :: struct {
	input:    [256]u8,          // NUL-terminated edit buffer (the command being typed)
	lines:    [dynamic]string,  // scrollback, oldest first (each line cloned, console-owned)
	history:  [dynamic]string,  // submitted commands, oldest first (Up/Down recall; console-owned)
	hist_pos: int,              // history browse cursor; -1 = editing a fresh (un-recalled) line
}

// CONSOLE_MAX_LINES caps the scrollback so a long session doesn't grow unbounded.
CONSOLE_MAX_LINES :: 512
// CONSOLE_MAX_HISTORY caps recallable command history the same way.
CONSOLE_MAX_HISTORY :: 200

console_init :: proc(c: ^Console) {
	c.lines = make([dynamic]string)
	c.history = make([dynamic]string)
	c.hist_pos = -1
}

console_destroy :: proc(c: ^Console) {
	for l in c.lines {
		delete(l)
	}
	delete(c.lines)
	for h in c.history {
		delete(h)
	}
	delete(c.history)
	c^ = {}
}

// console_print appends one output line (cloned into console ownership), dropping the oldest
// once the scrollback exceeds CONSOLE_MAX_LINES. Use console_printf for formatted lines.
console_print :: proc(c: ^Console, s: string) {
	append(&c.lines, strings.clone(s))
	if len(c.lines) > CONSOLE_MAX_LINES {
		delete(c.lines[0])
		ordered_remove(&c.lines, 0)
	}
}

console_printf :: proc(c: ^Console, format: string, args: ..any) {
	console_print(c, fmt.tprintf(format, ..args))
}

// console_panel draws the console: a scrolling output region above a full-width input box that
// stays focused for back-to-back commands. Returns the command the user submitted this frame
// (Enter) as a temp-allocator string, or "" — the caller dispatches it (and echoes via
// console_print). The input is cleared on submit; the scrollback auto-sticks to the bottom.
console_panel :: proc(c: ^Console) -> (submitted: string) {
	vp := imgui.GetMainViewport()
	imgui.SetNextWindowPos({vp.WorkPos.x + 8, vp.WorkPos.y + vp.WorkSize.y - 8}, .FirstUseEver, {0, 1})
	imgui.SetNextWindowSize({560, 240}, .FirstUseEver)
	if imgui.Begin("Console", nil, {.NoCollapse}) {
		// Output region: reserve a row for the input box pinned below it.
		footer := imgui.GetStyle().ItemSpacing.y + imgui.GetFrameHeightWithSpacing()
		if imgui.BeginChild("scrollback", {0, -footer}) {
			for l in c.lines {
				imgui.TextUnformatted(fmt.ctprintf("%s", l))
			}
			// Stick to the bottom while already there (so new output scrolls into view).
			if imgui.GetScrollY() >= imgui.GetScrollMaxY() {
				imgui.SetScrollHereY(1.0)
			}
		}
		imgui.EndChild()

		imgui.Separator()
		imgui.SetNextItemWidth(-1)
		buf := cstring(raw_data(c.input[:]))
		// CallbackHistory routes Up/Down to console_hist_cb (recall past commands); the ^Console
		// rides as user_data so the callback can reach the history + browse cursor.
		if imgui.InputTextWithHint(
			"##cmd",
			"command (e.g. tcl, player.additem) — Enter to run, ↑/↓ history",
			buf,
			uint(len(c.input)),
			{.EnterReturnsTrue, .CallbackHistory},
			console_hist_cb,
			c,
		) {
			line := string(buf)
			if line != "" {
				submitted = strings.clone(line, context.temp_allocator)
				console_history_push(c, line)
			}
			c.input[0] = 0 // clear for the next command
			c.hist_pos = -1 // back to a fresh line
			imgui.SetKeyboardFocusHere(-1) // keep focus on the input box
		}
	}
	imgui.End()
	return
}

// console_history_push appends a submitted command to the recall history (skipping an exact repeat of
// the most recent), dropping the oldest past the cap. Each entry is cloned into console ownership.
@(private)
console_history_push :: proc(c: ^Console, line: string) {
	if n := len(c.history); n > 0 && c.history[n - 1] == line {
		return // don't stack identical consecutive commands
	}
	append(&c.history, strings.clone(line))
	if len(c.history) > CONSOLE_MAX_HISTORY {
		delete(c.history[0])
		ordered_remove(&c.history, 0)
	}
}

// console_hist_cb is the imgui InputText history callback: Up/Down walk c.history and rewrite the edit
// buffer in place. hist_pos == -1 means "editing a fresh line"; Up from there jumps to the newest
// command, Down past the newest returns to the (empty) fresh line — standard shell recall.
@(private)
console_hist_cb :: proc "c" (data: ^imgui.InputTextCallbackData) -> i32 {
	c := (^Console)(data.UserData)
	if .CallbackHistory not_in data.EventFlag {
		return 0
	}
	prev := c.hist_pos
	n := len(c.history)
	#partial switch data.EventKey {
	case .UpArrow:
		if c.hist_pos == -1 {
			c.hist_pos = n - 1
		} else if c.hist_pos > 0 {
			c.hist_pos -= 1
		}
	case .DownArrow:
		if c.hist_pos != -1 {
			c.hist_pos += 1
			if c.hist_pos >= n {
				c.hist_pos = -1
			}
		}
	}
	if c.hist_pos != prev {
		entry := "" if c.hist_pos < 0 else c.history[c.hist_pos]
		// Replace the whole edit buffer with the recalled command (raw write — no allocation, so no
		// context needed in this "c" callback). Buf is imgui's internal buffer; set BufDirty so it
		// syncs back to c.input.
		raw := transmute([^]u8)data.Buf
		m := min(len(entry), int(data.BufSize) - 1)
		for i in 0 ..< m {
			raw[i] = entry[i]
		}
		raw[m] = 0
		data.BufTextLen = i32(m)
		data.CursorPos = i32(m)
		data.SelectionStart = i32(m)
		data.SelectionEnd = i32(m)
		data.BufDirty = true
	}
	return 0
}

// crosshair draws a small + at screen centre — the aim point for left-click picking.
crosshair :: proc() {
	vp := imgui.GetMainViewport()
	cx := vp.WorkPos.x + vp.WorkSize.x * 0.5
	cy := vp.WorkPos.y + vp.WorkSize.y * 0.5
	dl := imgui.GetForegroundDrawList()
	col := u32(0xB3FF_FFFF) // ABGR: white, ~0.7 alpha
	imgui.DrawList_AddLine(dl, {cx - 8, cy}, {cx + 8, cy}, col)
	imgui.DrawList_AddLine(dl, {cx, cy - 8}, {cx, cy + 8}, col)
}

// Installer_Action is what the first-boot installer UI reported this frame.
Installer_Action :: enum {
	None,
	Install,
	Quit,
}

// installer_screen draws the first-boot installer (ROADMAP Phase 1c): a centered
// window asking for the Skyrim source folder. `buf` is the caller-owned,
// NUL-terminated byte buffer the path box edits in place; `valid` is whether that
// path passed installer.valid_source — the CALLER computes it, so this package
// stays imgui-core only (no SDL, no installer dependency). Returns the user's
// action this frame; the caller installs / quits / keeps looping accordingly.
installer_screen :: proc(buf: []u8, valid: bool) -> Installer_Action {
	action := Installer_Action.None

	// Center the window over the work area on first appearance.
	vp := imgui.GetMainViewport()
	center := imgui.Vec2{vp.WorkPos.x + vp.WorkSize.x * 0.5, vp.WorkPos.y + vp.WorkSize.y * 0.5}
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	imgui.SetNextWindowSize({560, 0}, .Appearing)

	if imgui.Begin("Install SkyMod", nil, {.NoCollapse, .NoResize}) {
		imgui.TextWrapped("SkyMod builds its content from your own Skyrim install. Point it at the folder that contains Data/Skyrim.esm.")
		imgui.Spacing()
		imgui.TextUnformatted("Skyrim folder")
		imgui.SetNextItemWidth(-1)
		imgui.InputTextWithHint("##source", "/path/to/Skyrim", cstring(raw_data(buf)), uint(len(buf)))

		if valid {
			imgui.TextColored({0.40, 0.80, 0.45, 1}, "Found Data/Skyrim.esm — ready to install.")
		} else {
			imgui.TextColored({0.90, 0.55, 0.40, 1}, "No Data/Skyrim.esm in that folder.")
		}

		imgui.Spacing()
		imgui.Separator()
		imgui.Spacing()

		if !valid {imgui.BeginDisabled()}
		if imgui.Button("Install", {120, 0}) {action = .Install}
		if !valid {imgui.EndDisabled()}
		imgui.SameLine()
		if imgui.Button("Quit", {120, 0}) {action = .Quit}
	}
	imgui.End()
	return action
}

// Menu_Action is what the main-menu boot screen reported this frame.
Menu_Action :: enum {
	None,
	Continue, // load the most-recent save, then enter the world
	New,      // fresh game (empty overlay)
	Mods,     // open the mod manager (returns here on Back)
	Quit,
}

// main_menu_screen draws the boot main menu (ROADMAP Phase 3d): a centered Continue / New Game /
// Quit panel over the cleared frame. `has_save` enables Continue; `save_summary` is a one-line
// description of that save (e.g. "Save 3 — 12 changes"), built by the CALLER from the manifest so
// this package stays imgui-core (no worldstate dependency). Returns the user's choice this frame.
// (A multi-save Load browser arrives with save rotation — §7; one quicksave makes Continue enough.)
main_menu_screen :: proc(has_save: bool, save_summary: string) -> Menu_Action {
	action := Menu_Action.None

	vp := imgui.GetMainViewport()
	center := imgui.Vec2{vp.WorkPos.x + vp.WorkSize.x * 0.5, vp.WorkPos.y + vp.WorkSize.y * 0.5}
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	imgui.SetNextWindowSize({420, 0}, .Appearing)

	if imgui.Begin("SkyMod", nil, {.NoCollapse, .NoResize, .NoMove}) {
		imgui.Spacing()
		if !has_save {imgui.BeginDisabled()}
		if imgui.Button("Continue", {-1, 0}) {action = .Continue}
		if !has_save {imgui.EndDisabled()}
		if has_save {
			imgui.TextColored({0.65, 0.70, 0.78, 1}, fmt.ctprintf("%s", save_summary))
		} else {
			imgui.TextColored({0.55, 0.55, 0.58, 1}, "No save yet.")
		}
		imgui.Spacing()
		if imgui.Button("New Game", {-1, 0}) {action = .New}
		imgui.Spacing()
		if imgui.Button("Mods", {-1, 0}) {action = .Mods}
		imgui.Spacing()
		if imgui.Button("Quit", {-1, 0}) {action = .Quit}
	}
	imgui.End()
	return action
}

// Mod_Manager_Action is the mod-manager screen's top-level action this frame.
Mod_Manager_Action :: enum {
	None,
	Exit, // save the profile + return to the main menu (the top-right "Exit to Game")
}

// Mod_Entry_View is one mod-list row (left panel) — plain data so this package stays imgui-core (no
// mods/gamedb dependency). The caller builds it from the Profile each frame.
Mod_Entry_View :: struct {
	name:      string,
	enabled:   bool,
	locked:    bool, // base game: checked, non-interactive, can't move
	separator: bool, // organizational divider (no checkbox/plugins)
}

// Plugin_Row_View is one row of the derived plugin load order (right panel). source = the providing
// mod; pinned = a manual order override (the divergence overlay — none yet, always false for now).
Plugin_Row_View :: struct {
	name:   string,
	source: string,
	master: bool,
	pinned: bool,
}

// Missing_Master_View is one dependency failure shown in the plugins panel: `plugin` needs `master`,
// which isn't enabled. Plain data (imgui-core boundary); built from gamedb.Missing_Master each frame.
Missing_Master_View :: struct {
	plugin: string,
	master: string,
}

// Mod_Manager_Result is the screen's output for one frame: a top-level action plus at most one
// per-row mod edit (toggle / move) and the add buttons. The CALLER owns the Profile and applies these.
Mod_Manager_Result :: struct {
	action:         Mod_Manager_Action,
	toggled:        int, // mod row toggled, or -1
	move_from:      int, // drag-reorder source row, or -1 (paired with move_to)
	move_to:        int, // drag-reorder destination row, or -1
	add_empty:      bool,
	add_separator:  bool,
	switch_profile: int, // profile-picker row to switch to, or -1
	create_profile: bool,
	auto_disable_missing: bool, // "Auto-disable dependents" clicked (resolve missing masters)
}

// MOD_DND_PAYLOAD is the drag-drop payload type tag for reordering mod-list stripes.
@(private = "file")
MOD_DND_PAYLOAD: cstring : "MOD_ROW"

// mod_row_dnd wires the just-submitted mod-list stripe as both a drag SOURCE (payload = its row
// index) and a drop TARGET: when another stripe is dropped on it, it records the (from → this row)
// move into `r`. Call immediately after the row's imgui.Selectable. Locked/system rows don't call it,
// so they can neither be dragged nor act as a drop target (nothing lands above the locked prefix).
@(private = "file")
mod_row_dnd :: proc(r: ^Mod_Manager_Result, idx: i32) {
	if imgui.BeginDragDropSource() {
		src := idx
		imgui.SetDragDropPayload(MOD_DND_PAYLOAD, &src, uint(size_of(src)))
		imgui.TextUnformatted("move mod")
		imgui.EndDragDropSource()
	}
	if imgui.BeginDragDropTarget() {
		if pl := imgui.AcceptDragDropPayload(MOD_DND_PAYLOAD); pl != nil && pl.Data != nil {
			r.move_from = int((^i32)(pl.Data)^)
			r.move_to = int(idx)
		}
		imgui.EndDragDropTarget()
	}
}

// mod_manager_screen draws the MO2-style two-panel manager (the menu "socket" reached from the main
// menu's Mods entry): a top bar (profile picker + Exit-to-Game), the mod list on the left (priority,
// top→bottom; enable/reorder/add), and the DERIVED plugin load order on the right (read-only — it
// follows the mod list). Returns the frame's action + edits. Pure imgui-core — no mods/gamedb dep.
mod_manager_screen :: proc(
	profiles: []string,
	active_profile: string,
	mods_view: []Mod_Entry_View,
	plugins_view: []Plugin_Row_View,
	missing: []Missing_Master_View,
) -> (r: Mod_Manager_Result) {
	r = {action = .None, toggled = -1, move_from = -1, move_to = -1, switch_profile = -1}

	vp := imgui.GetMainViewport()
	imgui.SetNextWindowPos(vp.WorkPos, .Always)
	imgui.SetNextWindowSize(vp.WorkSize, .Always)
	if imgui.Begin(
		"##modmanager",
		nil,
		{.NoCollapse, .NoResize, .NoMove, .NoTitleBar, .NoBringToFrontOnFocus},
	) {
		// ── top bar: profile picker (left) + Exit-to-Game (right) ──
		imgui.TextUnformatted("Profile")
		imgui.SameLine()
		imgui.SetNextItemWidth(220)
		if imgui.BeginCombo("##profile", fmt.ctprintf("%s", active_profile)) {
			for name, i in profiles {
				if imgui.Selectable(fmt.ctprintf("%s##p%d", name, i), name == active_profile) {
					r.switch_profile = i
				}
			}
			imgui.Separator()
			if imgui.Selectable("+ New Profile") {r.create_profile = true}
			imgui.EndCombo()
		}
		imgui.SameLine()
		// Right-align the exit controls with a spacer.
		right_w: f32 = 300
		if pad := imgui.GetContentRegionAvail().x - right_w; pad > 0 {
			imgui.Dummy({pad, 0})
			imgui.SameLine()
		}
		imgui.SetNextItemWidth(180)
		if imgui.BeginCombo("##exittarget", "Exit to Main Menu") {
			imgui.Selectable("Exit to Main Menu", true)
			imgui.EndCombo()
		}
		imgui.SameLine()
		if imgui.Button("Go", {100, 0}) {r.action = .Exit}
		imgui.Separator()

		// ── two columns: mods | derived plugins ──
		avail := imgui.GetContentRegionAvail()
		if imgui.BeginChild("##mods", {avail.x * 0.5, 0}, {.Borders}) {
			imgui.TextColored({0.70, 0.78, 0.90, 1}, "MODS  (drag to reorder — top = priority)")
			imgui.Separator()
			// Each mod / separator is a full-width draggable stripe (locked system rows are fixed).
			// Drag a stripe onto another to move it there (insertion point) — see mod_row_dnd.
			for e, i in mods_view {
				idx := i32(i)
				if e.separator {
					// Separators reorder too (drag stripe + drop target), but have no checkbox.
					imgui.Selectable(fmt.ctprintf("— %s —##sep%d", e.name, i), false)
					mod_row_dnd(&r, idx)
					continue
				}
				if e.locked {
					// System row (base game / DLC / UI baseline): checked, non-interactive, fixed.
					imgui.BeginDisabled()
					v := e.enabled
					imgui.Checkbox(fmt.ctprintf("##c%d", i), &v)
					imgui.SameLine()
					imgui.Selectable(fmt.ctprintf("%s##row%d", e.name, i), false)
					imgui.EndDisabled()
					continue
				}
				v := e.enabled
				if imgui.Checkbox(fmt.ctprintf("##c%d", i), &v) {r.toggled = i}
				imgui.SameLine()
				imgui.Selectable(fmt.ctprintf("%s##row%d", e.name, i), false) // the draggable stripe
				mod_row_dnd(&r, idx)
			}
			imgui.Spacing()
			imgui.Separator()
			if imgui.Button("+ Empty Mod") {r.add_empty = true}
			imgui.SameLine()
			if imgui.Button("+ Separator") {r.add_separator = true}
		}
		imgui.EndChild()
		imgui.SameLine()
		if imgui.BeginChild("##plugins", {0, 0}, {.Borders}) {
			imgui.TextColored({0.70, 0.78, 0.90, 1}, "PLUGINS  (load order — derived from mods)")
			imgui.Separator()
			for pl, i in plugins_view {
				imgui.TextUnformatted(fmt.ctprintf("%3d   %s", i, pl.name))
				if pl.master {
					imgui.SameLine()
					imgui.TextColored({0.52, 0.66, 0.52, 1}, "[master]")
				}
				if pl.pinned {
					imgui.SameLine()
					imgui.TextColored({0.85, 0.70, 0.45, 1}, "pinned")
				}
			}
			imgui.Spacing()
			imgui.Separator()
			imgui.TextColored({0.55, 0.55, 0.58, 1}, "Manual overrides (0) — order follows the mod list")

			// Dependency validation: a plugin whose master isn't enabled would (in vanilla Skyrim)
			// CTD; here its refs are poisoned to dangle, but that's still a broken load — so surface
			// it loudly and offer the one-click fix (disable the offending mods).
			if len(missing) > 0 {
				imgui.Spacing()
				imgui.TextColored({0.95, 0.45, 0.40, 1}, fmt.ctprintf("⚠ %d missing master(s)", len(missing)))
				for mm in missing {
					imgui.Bullet()
					imgui.TextColored({0.90, 0.72, 0.55, 1}, fmt.ctprintf("%s  needs  %s", mm.plugin, mm.master))
				}
				imgui.Spacing()
				if imgui.Button("Auto-disable dependents") {r.auto_disable_missing = true}
			}
		}
		imgui.EndChild()
	}
	imgui.End()
	return
}

// loading_screen draws the full-bore load screen: a centered title + progress bar over the
// cleared frame while the streamer fills the playable bubble. `done`/`total` are model counts
// (total 0 = nothing to load → a full bar). Pure display; the caller pumps the streamer.
loading_screen :: proc(title: string, done, total: int) {
	frac := f32(1)
	if total > 0 {
		frac = clamp(f32(done) / f32(total), 0, 1)
	}

	vp := imgui.GetMainViewport()
	center := imgui.Vec2{vp.WorkPos.x + vp.WorkSize.x * 0.5, vp.WorkPos.y + vp.WorkSize.y * 0.5}
	imgui.SetNextWindowPos(center, .Always, {0.5, 0.5})
	imgui.SetNextWindowSize({480, 0}, .Always)

	if imgui.Begin("##loading", nil, {.NoCollapse, .NoResize, .NoTitleBar, .NoMove, .NoScrollbar}) {
		imgui.TextUnformatted(fmt.ctprintf("%s", title))
		imgui.Spacing()
		imgui.ProgressBar(frac, {-1, 0}, fmt.ctprintf("%d / %d", done, total))
	}
	imgui.End()
}

// loading_screen_busy draws an INDETERMINATE load screen for a synchronous task running on another
// thread (no real progress to report — e.g. the gamedb build parsing the masters). `anim` is a
// free-running seconds counter; the bar sweeps so the screen visibly animates instead of looking
// frozen. The caller pumps + renders this each frame until the worker signals done.
loading_screen_busy :: proc(title: string, anim: f32, frac: f32 = -1) {
	// frac >= 0 → a real progress bar with a percentage; frac < 0 → an indeterminate sweep driven by
	// `anim` (a free-running seconds counter), so the screen still animates before any progress.
	bar := frac
	overlay: cstring = ""
	if frac < 0 {
		bar = anim - f32(i64(anim)) // 0 → 1, repeating
	} else {
		overlay = fmt.ctprintf("%.0f%%", clamp(frac, 0, 1) * 100)
	}

	vp := imgui.GetMainViewport()
	center := imgui.Vec2{vp.WorkPos.x + vp.WorkSize.x * 0.5, vp.WorkPos.y + vp.WorkSize.y * 0.5}
	imgui.SetNextWindowPos(center, .Always, {0.5, 0.5})
	imgui.SetNextWindowSize({480, 0}, .Always)

	if imgui.Begin("##loadingbusy", nil, {.NoCollapse, .NoResize, .NoTitleBar, .NoMove, .NoScrollbar}) {
		imgui.TextUnformatted(fmt.ctprintf("%s", title))
		imgui.Spacing()
		imgui.ProgressBar(bar, {-1, 0}, overlay)
	}
	imgui.End()
}

// door_test_panel drives the --doortest sandbox: swing the "Door" hinge subtree open with a
// live angle slider about one of the Door node's three local axes, and toggle highlighting the
// "DoorBlack" aperture (drawn unlit so it's easy to spot). hinge_ok/black_ok report whether
// those named nodes were found in the NIF. Plain pointers (this package stays imgui-core).
door_test_panel :: proc(open_deg: ^f32, axis_idx: ^i32, highlight_black: ^bool, hinge_ok, black_ok: bool) {
	if imgui.Begin("Door test", nil, {.NoCollapse}) {
		imgui.TextUnformatted(fmt.ctprintf("hinge \"Door\": %v   DoorBlack: %v", hinge_ok, black_ok))
		imgui.Separator()
		imgui.SliderFloat("open (deg)", open_deg, -150, 150, "%.0f")
		imgui.SliderInt("hinge axis", axis_idx, 0, 2, "local %d (0=X 1=Y 2=Z)")
		imgui.Checkbox("highlight DoorBlack (unlit)", highlight_black)
		if imgui.Button("Close (0°)") {open_deg^ = 0}
		imgui.SameLine()
		if imgui.Button("Open (+90° outward)") {open_deg^ = 90}
		imgui.TextWrapped("Sandbox only — pure portals ship door-less; kept for future door polish.")
	}
	imgui.End()
}

// lod_test_legend labels the LOD test grid: rows are range conventions, columns are
// LOD levels, and it prints the chosen rock's BSLODTriShape triangle partition. Static
// (no interaction) — the user reads which row coarsens cleanly across the columns.
// phys_test_panel: drop-shape buttons for the --celltest physics scene. Returns which
// button (if any) was clicked this frame.
phys_test_panel :: proc(show_hitboxes: ^bool, noclip: ^bool, grounded: bool) -> (sphere: bool, cube: bool) {
	if imgui.Begin("Physics test", nil, {.NoCollapse}) {
		imgui.TextUnformatted("Drop a shape at the camera:")
		sphere = imgui.Button("Drop Sphere")
		imgui.SameLine()
		cube = imgui.Button("Drop Cube")
		imgui.Separator()
		imgui.Checkbox("Show collision hitboxes", show_hitboxes)
		imgui.Checkbox("No-clip camera (fly)", noclip)
		imgui.Separator()
		if noclip^ {
			imgui.TextUnformatted("Fly: WASD + Q/E, RMB look")
		} else {
			imgui.TextUnformatted("Walk: WASD, Shift sprint, Space jump")
			imgui.TextUnformatted(grounded ? "state: on ground" : "state: in air")
		}
	}
	imgui.End()
	return
}

lod_test_legend :: proc(lod_tris: [3]u32) {
	if imgui.Begin("LOD test", nil, {.NoCollapse}) {
		imgui.TextUnformatted("Rock at each LOD level, under 3 range conventions.")
		imgui.TextUnformatted("Columns (left→right): LOD 0 (full), LOD 1, LOD 2 (coarsest)")
		imgui.Separator()
		imgui.TextUnformatted("Row 0 (near):  SUFFIX  — drop front partitions")
		imgui.TextUnformatted("Row 1 (mid):   PREFIX  — keep first N triangles")
		imgui.TextUnformatted("Row 2 (far):   ISOLATED — that partition alone")
		imgui.Separator()
		imgui.TextUnformatted(
			fmt.ctprintf("partition lod_tris = [%d, %d, %d]", lod_tris[0], lod_tris[1], lod_tris[2]),
		)
		imgui.TextWrapped("Which ROW shows a clean full→coarse rock across the 3 columns?")
	}
	imgui.End()
}

// Lighting_Action is what the lighting configurator requests this frame: switch to a
// different preset (`select` = index into names, -1 = no change) and/or save the active one.
Lighting_Action :: struct {
	select:  int,
	save_as: bool, // write the active look as a preset in content/baselighting (caller reads the name)
}

// lighting_panel is the in-game lighting configurator (ROADMAP full-scene-lighting Phase A):
// a profile picker plus live controls for every active field of `p` (edited in place). All
// values are plain data — this package stays imgui-core-only; the app maps the profile to the
// renderer. Returns the picker/save action for the app to act on. Live edits are free (the
// renderer re-uploads a sub-kilobyte UBO each frame), so there's no perf-locked mode.
lighting_panel :: proc(
	p: ^lighting.Light_Profile,
	names: []string,
	current: int,
	save_name: []u8,
) -> (
	act: Lighting_Action,
) {
	act.select = -1
	if imgui.Begin("Lighting", nil, {.NoCollapse}) {
		preview: cstring = "—"
		if current >= 0 && current < len(names) {
			preview = fmt.ctprintf("%s", names[current])
		}
		if imgui.BeginCombo("profile", preview) {
			for n, i in names {
				if imgui.Selectable(fmt.ctprintf("%s", n), i == current) {
					act.select = i
				}
			}
			imgui.EndCombo()
		}

		imgui.SeparatorText("Sun")
		imgui.SliderFloat3("direction", &p.sun_dir, -1, 1)
		imgui.ColorEdit3("color", &p.sun_color)
		imgui.SliderFloat("intensity", &p.sun_intensity, 0, 4)

		imgui.SeparatorText("Ambient")
		imgui.ColorEdit3("sky##amb", &p.ambient_sky)
		imgui.ColorEdit3("ground", &p.ambient_ground)
		imgui.SliderFloat("amount", &p.ambient_intensity, 0, 2)
		imgui.SliderFloat("floor", &p.ambient_floor, 0, 0.5) // min light (dark-albedo guard)

		imgui.SeparatorText("Fog")
		imgui.ColorEdit3("fog color", &p.fog_color)
		imgui.DragFloat("start", &p.fog_start, 256, 0, 400000)
		imgui.DragFloat("end", &p.fog_end, 256, 0, 400000)
		imgui.SliderFloat("density", &p.fog_density, 0, 1)

		imgui.SeparatorText("Sky / material")
		imgui.ColorEdit3("sky color", &p.sky_color)
		imgui.SliderFloat("albedo lift", &p.albedo_lift, 0.3, 1.5) // <1 brightens dark-authored diffuse
		imgui.SliderFloat("spec scale", &p.spec_scale, 0, 4) // global specular strength remap
		imgui.SliderFloat("foliage spec", &p.foliage_spec, 0, 1) // matte over-shiny leaves/grass
		imgui.SliderFloat("normal strength", &p.normal_strength, 0, 2) // normal-map intensity
		imgui.SliderFloat("emissive scale", &p.emissive_scale, 0, 4) // glow strength

		imgui.SeparatorText("Tonemap / grade")
		ops := [?]cstring{"Reinhard", "ACES", "Filmic", "None"}
		mode := i32(p.tonemap)
		if imgui.BeginCombo("operator", ops[mode]) {
			for op, i in ops {
				if imgui.Selectable(op, i32(i) == mode) {
					p.tonemap = lighting.Tonemap(i)
				}
			}
			imgui.EndCombo()
		}
		imgui.SliderFloat("exposure", &p.exposure, 0.1, 4)
		imgui.SliderFloat("white point", &p.white_point, 0.5, 8)
		imgui.SliderFloat("contrast", &p.contrast, 0.5, 1.5)
		imgui.SliderFloat("saturation", &p.saturation, 0, 2)
		imgui.ColorEdit3("color filter", &p.color_filter)

		imgui.SeparatorText("Sun shadows")
		imgui.SliderFloat("shadow strength", &p.shadow_strength, 0, 1) // 0 = off
		imgui.SliderFloat("shadow softness", &p.shadow_softness, 0.25, 4) // PCF kernel scale
		imgui.SliderFloat("shadow bias", &p.shadow_bias, 0, 0.01, "%.4f") // acne vs peter-panning
		vshad := [?]cstring{"off", "proxy", "full"}
		vmode := i32(p.veg_shadows)
		if imgui.BeginCombo("veg shadows", vshad[vmode]) {
			for o, i in vshad {
				if imgui.Selectable(o, i32(i) == vmode) {
					p.veg_shadows = lighting.Veg_Shadows(i)
				}
			}
			imgui.EndCombo()
		}

		imgui.SeparatorText("Save as lighting mod")
		imgui.SetNextItemWidth(-1)
		imgui.InputTextWithHint("##lightname", "preset name", cstring(raw_data(save_name)), uint(len(save_name)))
		if imgui.Button("Save As Mod") {
			act.save_as = true
		}
	}
	imgui.End()
	return
}
