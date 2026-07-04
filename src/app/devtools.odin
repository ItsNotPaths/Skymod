package main

// Dev-harness gate + shared scaffold (cleanup.md 1.2). The throwaway test harnesses
// (--celltest, --doortest, --lodtest, --logotest, --phystest, --terraintest,
// --clutterprobe, --uitest) compile only when DEVTOOLS is on — by default that means
// debug builds, so `./release.sh` (-o:speed) ships without their ~1.5k LOC. Override
// per build with -define:DEVTOOLS=true/false. Every harness file wraps its body in
// `when DEVTOOLS`, and main()'s flag dispatch is gated the same way.

import "core:log"

import "../platform"
import "../render"
import "../settings"
import "../vfs"

DEVTOOLS :: #config(DEVTOOLS, ODIN_DEBUG)

// The harness CLI flags, for the compiled-out warning in main() (kept outside the
// `when` so a non-devtools build can still recognize — and explain — them).
DEV_FLAGS :: [?]string{
	"--lodtest", "--doortest", "--logotest", "--phystest",
	"--celltest", "--terraintest", "--clutterprobe", "--uitest",
}

when DEVTOOLS {
	// Dev_Boot is the shared scaffold for the windowed harnesses: window + renderer +
	// Dear ImGui + the vanilla archives mounted directly from source_game (no install,
	// no streaming). `up` records what came up so dev_shutdown is safe after a partial
	// boot — same pattern as Game/game_teardown.
	Dev_Boot :: struct {
		p:  platform.Platform,
		r:  render.Renderer,
		v:  vfs.VFS,
		up: struct {
			platform, render, ui, vfs: bool,
		},
	}

	// dev_boot brings the scaffold up (erroring under `flag` if source_game is unset).
	// Callers defer dev_shutdown(&d) FIRST, then bail if this returns false.
	dev_boot :: proc(d: ^Dev_Boot, title: cstring, cfg: ^settings.Config, flag: string) -> bool {
		src := resolve_source(cfg)
		if src == "" {
			log.errorf("%s: no valid install (set source_game_se / source_game_le / source_game in settings.txt)", flag)
			return false
		}
		ok: bool
		d.p, ok = platform.init(title, WINDOW_W, WINDOW_H)
		if !ok {
			return false
		}
		d.up.platform = true
		rok: bool
		d.r, rok = render.init(d.p.window)
		if !rok {
			log.error("render init failed; exiting")
			return false
		}
		d.up.render = true
		render.ui_init(&d.r)
		d.up.ui = true
		d.p.on_event = render.ui_process_event
		d.v = mount_game(src)
		d.up.vfs = true
		return true
	}

	dev_shutdown :: proc(d: ^Dev_Boot) {
		if d.up.vfs {vfs.destroy(&d.v)}
		if d.up.ui {render.ui_shutdown(&d.r)} // before render.shutdown — device still alive
		if d.up.render {render.shutdown(&d.r)}
		if d.up.platform {platform.shutdown(&d.p)}
	}
}
