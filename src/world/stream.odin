package world

// Exterior cell streaming (ROADMAP Section F). Keeps a square window of cells loaded
// around the player and loads/unloads the delta as they cross cell boundaries —
// WITHOUT hitching the frame. The heavy work (BSA read + NIF/DDS decode) runs on a
// worker thread; the main thread only plans the window (cheap) and does GPU uploads
// under a per-frame budget. Designed so LOD, terrain, and eviction bolt on:
//
//   plan (main)  ─reqs→  decode (worker)  ─ready→  upload (main, budgeted)
//
// - Requests are per-MODEL-PATH (deduped via `inflight`), so a mesh shared by many
//   cells decodes once. lod is carried on the request + chunk (only level 0 wired).
// - vfs.read is thread-safe (positional pread, no shared cursor), and decode_model
//   touches neither the GPU nor the cache — so the worker is lock-free against them.
//   The only shared state is the two queues (one mutex each) + the shutdown flag.
// - CPU bundles cross the thread boundary in `loader_alloc` (an explicit heap
//   allocator, NOT the debug tracking allocator the main thread wraps), so worker
//   allocate / main free never trips the leak tracker.
//
// Not yet (additive on this skeleton): terrain (LAND → a per-chunk mesh through the
// same pipeline), object/terrain LOD (fill the ring→lod table + LOD mesh paths),
// asset eviction (refcount models per loaded chunk, release at zero), and nearest-
// first request prioritization.

import "base:runtime"
import "core:log"
import "core:math"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

import "../assetdb"
import "../gamedb"
import smath "../math"
import "../render"
import "../vfs"

// How many decoded models the main thread uploads to the GPU per frame. Caps the
// per-frame upload cost so a burst of ready chunks fills in progressively (distant
// pop-in) instead of stalling one frame.
UPLOAD_BUDGET :: 6

// LOAD_BUDGET caps how many cells the main thread BUILDS (terrain mesh / object + grass
// instances, decoding any uncached model) per frame — so a window refill spreads over
// frames as progressive pop-in instead of one big hitch. LOD_SNAP keeps the coarse LOD
// rings (lod ≥ 1) anchored to a grid: they only recompute when the player crosses a
// LOD_SNAP-cell boundary, so moving within a snap cell does NOT churn the whole window
// (lod 0 still follows the player exactly, so full detail always surrounds you).
LOAD_BUDGET :: 8
LOD_SNAP :: 4

// LOAD_SCREEN_UPLOAD caps uploads per load-screen iteration. Big (the load screen has no
// gameplay to protect) but finite, so the frame still presents and the progress bar + ESC
// stay live instead of the window freezing while the whole bubble uploads in one go.
LOAD_SCREEN_UPLOAD :: 96

// Stream_Mode gates how the streamer fills. Streaming (the zero value, the steady state):
// rewindow on cell crossings + drain a budgeted few cells/uploads per frame so walking never
// hitches. Loading: a one-shot full-bore fill of the playable bubble with budgets lifted,
// driven by a load screen, used on boot + worldspace transitions before handing back to
// Streaming. (The future CDLOD terrain-texture build hangs off this Loading phase too.)
Stream_Mode :: enum {
	Streaming,
	Loading,
}

// Pending is a cell queued to load (sorted farthest-first so pop() yields the nearest).
@(private)
Pending :: struct {
	cid:  Form_ID,
	lod:  int,
	dist: int,
}

// Req is a model-decode request handed to the worker. path is borrowed from gamedb
// (stable for the session). extras = decode collision/proxy + build the pick copy —
// true for placed-instance models, false for draw-only meshes (LOD bake, billboards,
// grass), which are never picked or cooked.
@(private)
Req :: struct {
	path:   string,
	lod:    int,
	extras: bool,
}

// Result is a decoded model handed back to the main thread for GPU upload.
@(private)
Result :: struct {
	path: string,
	cpu:  assetdb.Cpu_Model,
}

// Streamer drives the window around the player over a Scene's chunk map.
Streamer :: struct {
	scene:        ^Scene,
	db:           ^gamedb.DB,
	v:            ^vfs.VFS, // borrowed from the scene's cache; decode_model reads it
	world_fid:    Form_ID,
	radius:       int, // outer window half-size in cells (= max content reach: full/obj/tree)
	full_radius:  int, // inner half-size loaded at full detail (objects+grass); beyond = terrain-only LOD
	obj_radius:   int, // distant prebaked-LOD static reach (MNAM); cells beyond load trees only
	tree_radius:  int, // distant tree-billboard reach (the cheap far-far tier; usually ≥ obj_radius)
	loader_alloc: runtime.Allocator, // explicit heap for cross-thread CPU bundles
	center_gx:    i32,
	center_gy:    i32,
	have_center:  bool,
	paused:       bool, // while set, stream_update is a no-op (chunks stay resident, worker idles)
	mode:         Stream_Mode, // Streaming (steady) vs Loading (full-bore boot/transition fill)
	load_target:  int, // models enqueued by the load-bubble build — the progress-bar denominator
	inflight:     map[string]bool, // model paths currently requested/decoding (main only)
	pending:      [dynamic]Pending, // cells planned but not yet built (drained under LOAD_BUDGET)

	// worker pool + queues. decode_model is thread-safe (positional pread VFS, no GPU/cache
	// touch — see the file header), so N workers drain the shared `reqs` queue concurrently;
	// the sema counts requests so any idle worker wakes. One worker is the degenerate pool.
	workers:  []^thread.Thread,
	reqs:     [dynamic]Req,
	ready:    [dynamic]Result,
	req_mu:   sync.Mutex,
	ready_mu: sync.Mutex,
	sema:     sync.Sema, // counts pending requests + the one shutdown wake
	running:  bool, // guarded by req_mu
}

// Stats is a snapshot for the debug overlay.
Stats :: struct {
	gx, gy:   i32,
	chunks:   int,
	inflight: int,
	reqs:     int,
	ready:    int,
}

// stream_init starts the worker and arms the streamer. The scene must already be
// scene_init'd (it provides the asset cache + VFS). loader_alloc must be a thread-safe
// heap allocator that is NOT the debug tracking allocator.
stream_init :: proc(
	st: ^Streamer,
	scene: ^Scene,
	db: ^gamedb.DB,
	world_fid: Form_ID,
	full_radius: int,
	obj_radius: int,
	tree_radius: int,
	loader_alloc: runtime.Allocator,
	decode_threads: int = 1,
) {
	st.scene = scene
	st.db = db
	st.v = scene.cache.v
	st.world_fid = world_fid
	// Distant objects + water are now BAKED per-quad once at load (object_lod / water_lod) and
	// CDLOD draws all terrain — so the streamer only needs the FULL-DETAIL BUBBLE (near terrain,
	// grass, collision, full meshes, animated per-cell water). The old lod≥1 rings (object/water
	// reach) are obsolete: keeping them resident cost per-cell water/iteration over the whole map
	// for nothing. obj_radius/tree_radius are retained only as the per-cell fallback's knobs.
	st.radius = full_radius
	st.full_radius = full_radius
	st.obj_radius = obj_radius
	st.tree_radius = tree_radius
	// Guard against a reach that swallows the whole worldspace: the streaming window is a
	// (2·radius+1)² square, and EVERY cell in it stays resident (each LOD cell is a Chunk that
	// every draw/shadow pass iterates). Past ~40 cells the window rivals a small worldspace's
	// extent, so chunk count — and render time — climbs until the whole map is loaded. Loud so
	// a too-large object_lod_distance/tree_lod_distance never silently bleeds FPS again.
	if st.radius > 40 {
		log.warnf(
			"stream: window radius %d cells (%d-wide, %d cells) is very large — may load most/all of the worldspace and degrade FPS as cells fill; lower object_lod_distance/tree_lod_distance",
			st.radius, 2 * st.radius + 1, (2 * st.radius + 1) * (2 * st.radius + 1),
		)
	}
	st.loader_alloc = loader_alloc
	st.inflight = make(map[string]bool)
	st.running = true
	// Decode pool: every worker runs the same loop over the shared queue. More threads = a
	// fuller `ready` queue (the full-load screen and walking pop-in both drain it faster).
	n := max(decode_threads, 1)
	st.workers = make([]^thread.Thread, n)
	for i in 0 ..< n {
		w := thread.create(worker_proc)
		w.data = st
		st.workers[i] = w
		thread.start(w)
	}
	stream_index_persistent(st) // bucket persistent refs (doors/bridges/gates) by grid → merge with cells
	bake_object_lod(st) // whole-worldspace distant-object LOD, merged per quad, once (object_lod.odin)
	bake_water_lod(st) // whole-worldspace distant water, merged per quad at real heights (water_lod.odin)
}

// stream_index_persistent spatially re-buckets the worldspace's PERSISTENT cell refs by grid cell
// into scene.persistent_by_grid. The ESM groups them logically in one persistent cell at scattered
// absolute coords (load doors, city gates, bridges, quest set-dressing), so the grid streamer never
// reaches them — but each has a world position, so we bucket by floor(pos/CELL_SIZE) and merge each
// bucket into its grid chunk at build (merge_persistent). They then load/collide/unload with the
// grid like any cell ref, instead of one always-resident, fully-physics-cooked chunk (the old holdover
// that cooked collision for the WHOLE worldspace's persistent refs regardless of player position).
// Cheap: no models/collision here, just the ref grouping. The load-door traversal index is separate
// (rebuild_ext_doors, gamedb-sourced) and does NOT depend on this.
@(private)
stream_index_persistent :: proc(st: ^Streamer) {
	free_persistent_grid(st.scene) // drop the previous worldspace's buckets (retarget)
	pcid, ok := gamedb.world_persistent_cell(st.db, st.world_fid)
	if !ok {
		return
	}
	n := 0
	for refs in ([2][]gamedb.Ref{gamedb.refs_of(st.db, pcid), gamedb.actors_of(st.db, pcid)}) {
		for r in refs {
			key := [2]i32{i32(math.floor(r.pos.x / CELL_SIZE)), i32(math.floor(r.pos.y / CELL_SIZE))}
			// Map-of-dynamic-array: read the header, append to the local copy (may realloc), write back —
			// safe even when inserting new keys rehashes the map (a live &m[key] would dangle).
			bucket := st.scene.persistent_by_grid[key]
			append(&bucket, r)
			st.scene.persistent_by_grid[key] = bucket
			n += 1
		}
	}
	log.infof(
		"stream: indexed %d persistent refs across %d grid cells (0x%08X)",
		n, len(st.scene.persistent_by_grid), pcid,
	)
}

// stream_destroy stops the worker and frees the streamer's own state. Call BEFORE
// scene_destroy (the worker must be stopped before the cache it feeds is freed).
stream_destroy :: proc(st: ^Streamer) {
	if len(st.workers) == 0 {
		return // never stream_init'd (e.g. worldspace not found) — nothing to tear down
	}
	sync.mutex_lock(&st.req_mu)
	st.running = false
	sync.mutex_unlock(&st.req_mu)
	// One post per worker so every one wakes and sees !running (the shutdown flag is shared).
	for _ in st.workers {
		sync.sema_post(&st.sema)
	}
	for w in st.workers {
		thread.join(w)
		thread.destroy(w)
	}
	delete(st.workers)
	// Free any decoded-but-not-uploaded bundles the worker left behind.
	for len(st.ready) > 0 {
		res := pop(&st.ready)
		assetdb.free_cpu_model(res.cpu, st.loader_alloc)
	}
	delete(st.reqs)
	delete(st.ready)
	delete(st.inflight)
	delete(st.pending)
	st^ = {}
}

// (hole stream-requests :tags (threading world assets) :sev gap :needs (sim-cell)) the streamer picks cells from main's camera and builds everything itself. Decided (user, 2026-09-27): the streamer loads every asset kind (meshes, textures, collision, skeletons, clips) for every consumer; the sim requests what the live cells need and owns placement; the streamer picks visual-only distant LOD (terrain, object LOD, grass) from the camera itself.
// stream_update is called every frame with the player's world position. It re-windows
// only when the player changes cell (cheap early-out otherwise), then drains decoded
// models into the GPU under the per-frame budget.
stream_update :: proc(st: ^Streamer, pos: smath.Vec3) {
	if st.paused {
		return // frozen (player is in an interior): keep the exterior window warm, untouched
	}
	gx := i32(math.floor(pos.x / CELL_SIZE))
	gy := i32(math.floor(pos.y / CELL_SIZE))
	if !st.have_center || gx != st.center_gx || gy != st.center_gy {
		st.center_gx, st.center_gy, st.have_center = gx, gy, true
		rewindow(st)
	}
	drain_loads(st) // build a budgeted number of queued cells this frame (no spike)
	drain_ready(st, UPLOAD_BUDGET)
}

// stream_begin_load arms Loading mode at `pos`: it plans the playable BUBBLE (the full-detail
// cells around the player — objects + grass + terrain, NOT the distant LOD rings) and BUILDS
// them all now, with no per-frame cap, so every model the spawn view needs is enqueued up
// front. The decode pool then chews through it while the load screen pumps uploads. Distant
// terrain/object LOD is left for Streaming to fill lazily once the player is in. Call after
// stream_init + spawn, before the gameplay loop.
stream_begin_load :: proc(st: ^Streamer, pos: smath.Vec3) {
	if len(st.workers) == 0 {
		return // streamer never armed (no worldspace) — stay in the zero-value Streaming mode
	}
	st.mode = .Loading
	st.center_gx = i32(math.floor(pos.x / CELL_SIZE))
	st.center_gy = i32(math.floor(pos.y / CELL_SIZE))
	st.have_center = true

	// Plan only the full-detail bubble: temporarily clamp the window to full_radius so rewindow
	// queues those cells (all at lod 0), then restore it so the first Streaming rewindow expands
	// back out to the LOD rings. (Post-CDLOD the rings leave the streamer and this just shrinks.)
	saved := st.radius
	st.radius = st.full_radius
	rewindow(st)
	st.radius = saved

	// Build the whole bubble immediately — no LOAD_BUDGET — so inflight reflects the full set.
	// This runs BEFORE the frame loop, so nothing else drains the GPU: each cell's terrain/water/
	// grass meshes upload as their own submits, and SDL frees their staging only on copy-completion.
	// Without a periodic drain the deferred-free staging piles up across the whole bubble and
	// exhausts the host-visible heap (tiny binds then fail even with VRAM free — the rd≥6 crash).
	// Drain every few cells so at most a handful of cells' staging is ever in flight.
	built := 0
	for len(st.pending) > 0 {
		p := pop(&st.pending)
		if c, ok := st.scene.chunks[p.cid]; ok && c.lod == p.lod {
			continue
		}
		load_streamed_cell(st, p.cid, p.lod, p.dist)
		built += 1
		if built % 8 == 0 {
			render.gpu_drain(st.scene.cache.r)
		}
	}
	render.gpu_drain(st.scene.cache.r) // final drain: reclaim the last partial batch's staging
	st.load_target = len(st.inflight)
	log.infof("stream: full-load bubble armed — %d models to decode", st.load_target)
}

// stream_pump_load advances Loading by one load-screen iteration: upload a big batch of decoded
// models. Returns progress (done/total models) and whether the bubble is fully resident — at
// which point it flips back to Streaming and the caller drops into the gameplay loop. The
// denominator is the snapshot taken in stream_begin_load; failed decodes still clear inflight
// (drain_ready marks them failed), so this always converges.
stream_pump_load :: proc(st: ^Streamer) -> (done, total: int, complete: bool) {
	drain_ready(st, LOAD_SCREEN_UPLOAD)
	total = st.load_target
	done = total - len(st.inflight)
	complete = len(st.inflight) == 0
	if complete {
		st.mode = .Streaming
		// Force the first Streaming frame to rewindow at the full radius: the bubble build only
		// planned full_radius, so the distant LOD rings still need queuing (they then stream in
		// lazily under budget). Clearing have_center makes stream_update re-plan even though the
		// player hasn't crossed a cell yet.
		st.have_center = false
	}
	return
}

// stream_loading reports whether the streamer is mid full-load (drives the load-screen loop).
stream_loading :: proc(st: ^Streamer) -> bool {
	return st.mode == .Loading
}

// stream_pause freezes (true) or resumes (false) the streamer. While paused, stream_update
// is a no-op: the loaded exterior chunks stay resident untouched and the worker idles on its
// sema. Used when the player steps into an interior; resumed (with a re-window) on return.
stream_pause :: proc(st: ^Streamer, paused: bool) {
	st.paused = paused
}

// stream_retarget switches the streamer to a DIFFERENT worldspace (e.g. a cross-worldspace
// city gate, Tamriel ↔ WhiterunWorld): unloads every current chunk, points at the new world,
// and forces a re-window on the next stream_update. The worker + asset cache stay alive —
// decoded models are world-agnostic (keyed by path), so a shared mesh stays cached across
// worlds. Far terrain + any door index are per-worldspace and the caller's to rebuild.
stream_retarget :: proc(st: ^Streamer, world_fid: Form_ID) {
	for _, &chunk in st.scene.chunks {
		release_chunk_assets(st.scene, &chunk, deindex = false) // resident set cleared below
	}
	clear(&st.scene.chunks)
	clear(&st.scene.resident) // whole resident set is gone with the chunks
	clear(&st.pending)
	clear(&st.inflight)
	st.world_fid = world_fid
	st.have_center = false
	st.paused = false
	stream_index_persistent(st) // re-bucket the new worldspace's persistent refs by grid
	bake_object_lod(st) // re-bake distant-object LOD for the new worldspace
	bake_water_lod(st) // re-bake distant water for the new worldspace
}

// stream_collapse unloads every loaded chunk beyond `keep_radius` cells (Chebyshev) of the
// current center, freeing their terrain/grass/object/instance GPU buffers — so a paused
// exterior keeps only a small FIXED window resident while the player is in an interior (the
// far LOD/terrain rings, the costly part, are dropped). The worker + asset cache stay alive,
// so the immediate surroundings return instantly and the outer rings re-stream on resume.
stream_collapse :: proc(st: ^Streamer, keep_radius: int) {
	if !st.have_center {
		return
	}
	r := keep_radius
	to_unload := make([dynamic]Form_ID, 0, 64, context.temp_allocator)
	for cid, chunk in st.scene.chunks {
		if int(max(abs(chunk.gx - st.center_gx), abs(chunk.gy - st.center_gy))) > r {
			append(&to_unload, cid)
		}
	}
	for cid in to_unload {
		chunk := st.scene.chunks[cid]
		release_chunk_assets(st.scene, &chunk)
		delete_key(&st.scene.chunks, cid)
	}
	clear(&st.pending) // any queued loads are stale; resume replans from the arrival cell
}

// stream_stats snapshots counts for the overlay (briefly locks the queues).
stream_stats :: proc(st: ^Streamer) -> Stats {
	sync.mutex_lock(&st.req_mu)
	nreq := len(st.reqs)
	sync.mutex_unlock(&st.req_mu)
	sync.mutex_lock(&st.ready_mu)
	nready := len(st.ready)
	sync.mutex_unlock(&st.ready_mu)
	return Stats {
		gx = st.center_gx,
		gy = st.center_gy,
		chunks = len(st.scene.chunks),
		inflight = len(st.inflight),
		reqs = nreq,
		ready = nready,
	}
}

// --- internals ---

// LOD_RING_WIDTH is how many cells each LOD level spans beyond the full-detail radius;
// MAX_LOD caps the coarsest level (lod 3 = stride 8 = a 5×5 mesh).
LOD_RING_WIDTH :: 3
MAX_LOD :: 3

// lod_for maps a cell's Chebyshev distance (in cells) from the player to a detail level:
// within full_radius = 0 (full: objects + textured terrain + grass), then coarser by ring.
@(private)
lod_for :: proc(cheb_dist, full_radius: int) -> int {
	if cheb_dist <= full_radius {
		return 0
	}
	return min(1 + (cheb_dist - full_radius - 1) / LOD_RING_WIDTH, MAX_LOD)
}

// snap_to rounds a cell coordinate to the nearest multiple of `step` (anchors the coarse
// LOD rings to a grid so they don't churn on every cell crossing).
@(private)
snap_to :: proc(v, step: i32) -> i32 {
	return i32(math.round(f32(v) / f32(step))) * step
}

// (hole cell-handoff :tags (threading world physics) :sev gap :needs (sim-cell stream-requests)) rewindow and load_streamed_cell pick the live cells and add and remove Jolt bodies on main. Decided (user, 2026-09-27): the sim decides which cells are live and builds their bodies; the streamer only delivers the collision blobs it asked for, and a drain leaves no request half-applied.
// rewindow (cheap, on cell crossing) computes the desired cell→LOD set around the player,
// unloads chunks that left the window or changed LOD, and REPLANS the pending load queue.
// The actual building happens in drain_loads under LOAD_BUDGET — so a crossing never
// blocks the frame. lod 0 follows the player exactly (full detail); coarser rings anchor
// to a LOD_SNAP grid (stable as the player moves within a snap cell → no whole-window churn).
@(private)
rewindow :: proc(st: ^Streamer) {
	r := i32(st.radius)
	snap_gx := snap_to(st.center_gx, LOD_SNAP)
	snap_gy := snap_to(st.center_gy, LOD_SNAP)

	Want :: struct {
		lod:  int,
		dist: int,
	}
	desired := make(map[Form_ID]Want, (2 * st.radius + 1) * (2 * st.radius + 1), context.temp_allocator)
	for dy := -r; dy <= r; dy += 1 {
		for dx := -r; dx <= r; dx += 1 {
			d_player := int(max(abs(dx), abs(dy)))
			lod: int
			if d_player <= st.full_radius {
				lod = 0 // full detail always surrounds the player (player-anchored)
			} else {
				cgx, cgy := st.center_gx + dx, st.center_gy + dy
				d_snap := int(max(abs(cgx - snap_gx), abs(cgy - snap_gy)))
				lod = max(lod_for(d_snap, st.full_radius), 1) // coarse rings: snap-anchored
			}
			// (hole gamedb-for-streamer :tags (assets unclaimed) :sev wish) the streamer queries gamedb (cell_at, refs_of, model_of, cell_terrain); a streamer in Rust needs a C-ABI read view of gamedb or its own index.
			if cid, ok := gamedb.cell_at(st.db, st.world_fid, st.center_gx + dx, st.center_gy + dy);
			   ok {
				desired[cid] = {lod, d_player}
			}
		}
	}

	// Unload chunks that LEFT the window (immediate — they're out of view). LOD-changed
	// chunks are NOT unloaded here: they keep rendering at their old LOD until drain_loads
	// rebuilds + swaps them (build-before-release → no blink-out / "regeneration" cascade).
	to_unload := make([dynamic]Form_ID, 0, 16, context.temp_allocator)
	for cid, _ in st.scene.chunks {
		if _, ok := desired[cid]; !ok {
			append(&to_unload, cid)
		}
	}
	for cid in to_unload {
		chunk := st.scene.chunks[cid]
		release_chunk_assets(st.scene, &chunk)
		delete_key(&st.scene.chunks, cid)
	}

	// Replan the pending queue: cells not resident OR at the wrong LOD (the latter stay
	// visible at their old LOD meanwhile). Farthest-first so pop() refines nearest first.
	clear(&st.pending)
	for cid, want in desired {
		if c, ok := st.scene.chunks[cid]; ok && c.lod == want.lod {
			continue // already resident at the right LOD
		}
		append(&st.pending, Pending{cid = cid, lod = want.lod, dist = want.dist})
	}
	slice.sort_by(st.pending[:], proc(a, b: Pending) -> bool {return a.dist > b.dist})
}

// load_streamed_cell builds one cell at its LOD. lod 0 (the full-detail ring) = near textured
// terrain + grass + full objects. lod ≥ 1 = distant OBJECT LOD only (Skyrim's prebaked MNAM
// meshes) — NO per-cell terrain, because the CDLOD field already draws all terrain out to the
// horizon. So object reach is governed by obj_radius, decoupled from terrain entirely.
@(private)
load_streamed_cell :: proc(st: ^Streamer, cid: Form_ID, lod: int, dist: int) {
	chunk: Chunk
	if lod == 0 {
		chunk = build_overlaid_chunk(st.scene, st.db, cid) // ESM baseline ⊕ created refs (full-detail ring)
	} else {
		chunk = chunk_meta(st.db, cid) // grid/bounds only: no terrain mesh, no near instances
	}
	chunk.lod = lod
	expand_scene_bounds(st.scene, chunk)
	load_water(st.scene, st.db, &chunk) // flat per-cell plane (cheap; any LOD)
	if lod == 0 {
		load_terrain(st.scene, st.db, &chunk) // near textured terrain (CDLOD covers beyond)
		load_grass(st.scene, st.db, &chunk)
		build_chunk_physics(st.scene, st.db, &chunk) // static collision (full-detail bubble only)
	}
	// lod ≥ 1 carries no per-cell objects now — distant objects are baked per-quad once at load
	// (bake_object_lod), drawn via draw_object_lod. Far cells stay lean (water + bounds only).
	// Build-before-release: the new chunk is fully built; now free the OLD chunk (a LOD
	// swap that was rendering until this instant) and replace it in one step — no gap.
	if old, ok := &st.scene.chunks[cid]; ok {
		release_chunk_assets(st.scene, old)
	}
	st.scene.chunks[cid] = chunk

	// Enqueue model decodes off-thread (the cheap instance/terrain work stayed on main;
	// the heavy BSA+NIF+DDS decode runs on the worker → no stutter, models pop in lazily).
	resident := &st.scene.chunks[cid]
	index_instances(st.scene, resident)
	apply_overlay(st.scene, resident) // baseline ⊕ overlay (disabled/moved/scaled) before collision builds
	if lod == 0 {
		acquire_chunk_assets(st.scene, resident) // D1: pin this chunk's instance + grass models
		note_loaded(st.scene, cid)
		for inst in resident.instances {
			enqueue_model(st, inst.model_path)
		}
		for b in resident.grass {
			enqueue_model(st, b.model_path, extras = false) // grass: draw-only (no pick/collision)
		}
	}
	// lod ≥ 1: nothing to enqueue — distant-object meshes were enqueued by bake_object_lod.
	_ = dist // distance only mattered for the old per-cell object reach gating
}

// enqueue_model requests an off-thread decode for a model path unless it's already cached
// or in flight (main-thread dedup). The dedup is path-only, so a path must always be
// requested with the SAME `extras` — holds today because draw-only paths (LOD meshes,
// billboards, grass) never appear as cell-instance models (see decode_model's doc).
@(private)
enqueue_model :: proc(st: ^Streamer, path: string, extras := true) {
	if path == "" ||
	   assetdb.has_model(&st.scene.cache, path) ||
	   assetdb.is_failed(&st.scene.cache, path) ||
	   st.inflight[path] {
		return
	}
	st.inflight[path] = true
	enqueue(st, Req{path = path, lod = 0, extras = extras})
}

// drain_loads builds up to LOAD_BUDGET queued cells this frame (nearest first), spreading
// a window refill over frames as progressive pop-in. Logs if the budget's work overran a
// frame so the profile still surfaces an expensive cell.
@(private)
drain_loads :: proc(st: ^Streamer) {
	if len(st.pending) == 0 {
		return
	}
	t_start := time.tick_now()
	built := 0
	for built < LOAD_BUDGET && len(st.pending) > 0 {
		p := pop(&st.pending) // nearest (queue is farthest-first)
		if c, ok := st.scene.chunks[p.cid]; ok && c.lod == p.lod {
			continue // already resident at the right LOD (a reload at the OLD lod still loads)
		}
		load_streamed_cell(st, p.cid, p.lod, p.dist)
		built += 1
	}
	ms := time.duration_milliseconds(time.tick_since(t_start))
	if ms > 8 {
		log.infof("stream: built %d cells in %.1fms (%d still pending)", built, ms, len(st.pending))
	}
}

@(private)
enqueue :: proc(st: ^Streamer, req: Req) {
	sync.mutex_lock(&st.req_mu)
	append(&st.reqs, req)
	sync.mutex_unlock(&st.req_mu)
	sync.sema_post(&st.sema)
}

// drain_ready uploads up to `budget` decoded models and clears their in-flight marks. Lazy
// draw resolution then makes their instances appear. Streaming passes UPLOAD_BUDGET (a small
// per-frame cap so walking never hitches); the load screen passes a much larger batch.
@(private)
drain_ready :: proc(st: ^Streamer, budget: int) {
	for n := 0; n < budget; n += 1 {
		sync.mutex_lock(&st.ready_mu)
		if len(st.ready) == 0 {
			sync.mutex_unlock(&st.ready_mu)
			break
		}
		res := pop(&st.ready)
		sync.mutex_unlock(&st.ready_mu)

		if res.cpu.ok {
			assetdb.upload_cpu_model(&st.scene.cache, res.cpu)
		} else {
			assetdb.mark_failed(&st.scene.cache, res.path) // missing / no shapes — don't re-enqueue
		}
		assetdb.free_cpu_model(res.cpu, st.loader_alloc)
		delete_key(&st.inflight, res.path)
	}
}

// worker_proc is the decode thread: wait for a request, decode the model into the
// loader allocator (no GPU, no cache), hand it back. Exits when running is cleared.
@(private)
worker_proc :: proc(t: ^thread.Thread) {
	st := (^Streamer)(t.data)
	for {
		sync.sema_wait(&st.sema)

		sync.mutex_lock(&st.req_mu)
		if !st.running {
			sync.mutex_unlock(&st.req_mu)
			return
		}
		if len(st.reqs) == 0 {
			sync.mutex_unlock(&st.req_mu)
			continue
		}
		req := pop(&st.reqs)
		sync.mutex_unlock(&st.req_mu)

		cpu := assetdb.decode_model(st.v, req.path, req.lod, st.loader_alloc, req.extras)

		sync.mutex_lock(&st.ready_mu)
		append(&st.ready, Result{path = req.path, cpu = cpu})
		sync.mutex_unlock(&st.ready_mu)

		free_all(context.temp_allocator) // reset this thread's scratch after each decode
	}
}
