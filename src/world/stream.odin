package world

// The exterior loader. The sim picks the live cells (window.odin) and tells main by ref events; for
// each added cell main builds a render chunk and the streamer decodes its models on worker threads,
// then uploads them under a per-frame budget. The streamer decorates each new chunk with terrain,
// water and grass, a few cells per frame.
//
//   Cell_Added (main)  ─reqs→  decode (worker)  ─ready→  upload (main, budgeted)
//
// - Requests are per model path (deduped via `inflight`), so a mesh shared by many cells decodes once.
// - vfs.read is thread-safe (positional pread) and decode_model touches neither the GPU nor the cache,
//   so the workers are lock-free against them. The only shared state is the two queues and the
//   shutdown flag.
// - CPU bundles cross the thread boundary in `loader_alloc` (an explicit heap allocator, not the debug
//   tracking allocator main wraps), so worker allocate / main free never trips the leak tracker.
// - An upload also puts the model's collision in the collision store, where the sim builds bodies.

import "base:runtime"
import "core:log"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

import "../assetdb"
import "../gamedb"
import "../render"
import "../vfs"

// How many decoded models the main thread uploads to the GPU per frame. Caps the
// per-frame upload cost so a burst of ready chunks fills in progressively (distant
// pop-in) instead of stalling one frame.
UPLOAD_BUDGET :: 6

// DECORATE_BUDGET caps how many new chunks get their terrain, water and grass per frame.
DECORATE_BUDGET :: 8

// LOAD_SCREEN_UPLOAD caps uploads per load-screen iteration. Big (the load screen has no
// gameplay to protect) but finite, so the frame still presents and the progress bar + ESC
// stay live instead of the window freezing while the whole bubble uploads in one go.
LOAD_SCREEN_UPLOAD :: 96

// Stream_Mode gates how the streamer fills. Streaming (the zero value, the steady state): a budgeted
// few decorations and uploads per frame so walking never hitches. Loading: behind a load screen, every
// queued chunk decorated at once and uploads in big batches, until the bubble's models are in.
Stream_Mode :: enum {
	Streaming,
	Loading,
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

// Streamer loads the exterior scene's chunks as the sim adds them.
Streamer :: struct {
	scene:        ^Scene,
	db:           ^gamedb.DB,
	v:            ^vfs.VFS, // borrowed from the scene's cache; decode_model reads it
	world_fid:    Form_ID, // the worldspace the distant LOD is baked for
	loader_alloc: runtime.Allocator, // explicit heap for cross-thread CPU bundles
	mode:         Stream_Mode, // Streaming (steady) vs Loading (full-bore boot/transition fill)
	load_target:  int, // models in flight when the load began — the progress-bar denominator
	inflight:     map[string]bool, // model paths currently requested/decoding (main only)
	undecorated:  [dynamic]Form_ID, // new chunks still without terrain, water and grass, nearest first

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
	chunks:   int,
	inflight: int,
	reqs:     int,
	ready:    int,
}

// stream_init starts the workers and bakes the worldspace's distant LOD. The scene must already be
// scene_init'd (it provides the asset cache + VFS). loader_alloc must be a thread-safe heap allocator
// that is NOT the debug tracking allocator.
stream_init :: proc(
	st: ^Streamer,
	scene: ^Scene,
	db: ^gamedb.DB,
	world_fid: Form_ID,
	loader_alloc: runtime.Allocator,
	decode_threads: int = 1,
) {
	st.scene = scene
	st.db = db
	st.v = scene.cache.v
	st.world_fid = world_fid
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
	bake_object_lod(st) // whole-worldspace distant-object LOD, merged per quad, once (object_lod.odin)
	bake_water_lod(st) // whole-worldspace distant water, merged per quad at real heights (water_lod.odin)
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
	delete(st.undecorated)
	st^ = {}
}

// (hole stream-requests :tags (threading world assets) :sev gap) the only request the streamer takes is a live cell (Cell_Added), for its models. Decided (user, 2026-09-27): the streamer loads every asset kind for every consumer. Wanted: a request for any asset kind with a reply when it is in, so skeletons, clips, the collision store's own NIF reads (furniture markers, ProjectileNode) and the interior load go through it too.
// stream_apply builds or drops the render chunk for a cell the sim made live or retired. Placement
// events are the scene's (apply_ref_event).
stream_apply :: proc(st: ^Streamer, e: Ref_Event) {
	if len(st.workers) == 0 {return}
	#partial switch v in e {
	case Cell_Added:
		chunk := chunk_meta(st.db, v.cell) // grid/bounds only: no terrain mesh, no near instances
		populate(&chunk, v.refs)
		expand_scene_bounds(st.scene, chunk)
		st.scene.chunks[v.cell] = chunk
		resident := &st.scene.chunks[v.cell]
		index_instances(st.scene, resident)
		acquire_chunk_assets(st.scene, resident) // D1: pin this chunk's instance models
		for inst in resident.instances {enqueue_model(st, inst.model_path)}
		append(&st.undecorated, v.cell)
	case Cell_Removed:
		drop_chunk(st, v.cell)
	}
}

// stream_update decorates a budgeted few new chunks and uploads decoded models. Call every frame.
stream_update :: proc(st: ^Streamer) {
	decorate(st, DECORATE_BUDGET)
	drain_ready(st, UPLOAD_BUDGET)
}

// stream_begin_load arms Loading: every chunk still undecorated is decorated now, with no per-frame
// cap, so every model the bubble needs is in flight. The decode pool then chews through it while the
// load screen pumps uploads. Call once the sim's bubble cells have reached the scene.
stream_begin_load :: proc(st: ^Streamer) {
	if len(st.workers) == 0 {
		return // streamer never armed (no worldspace) — stay in the zero-value Streaming mode
	}
	st.mode = .Loading
	decorate(st, max(int))
	render.gpu_drain(st.scene.cache.r) // reclaim the last partial batch's staging
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
	if complete {st.mode = .Streaming}
	return
}

// stream_loading reports whether the streamer is mid full-load (drives the load-screen loop).
stream_loading :: proc(st: ^Streamer) -> bool {
	return st.mode == .Loading
}

// stream_retarget bakes the distant LOD of a different worldspace (a cross-worldspace city gate,
// Tamriel ↔ WhiterunWorld). The old chunks go as the sim retires their cells. The workers and asset
// cache stay alive: decoded models are keyed by path, so a shared mesh stays cached across worlds.
stream_retarget :: proc(st: ^Streamer, world_fid: Form_ID) {
	st.world_fid = world_fid
	bake_object_lod(st) // re-bake distant-object LOD for the new worldspace
	bake_water_lod(st) // re-bake distant water for the new worldspace
}

// stream_stats snapshots counts for the overlay (briefly locks the queues).
stream_stats :: proc(st: ^Streamer) -> Stats {
	sync.mutex_lock(&st.req_mu)
	nreq := len(st.reqs)
	sync.mutex_unlock(&st.req_mu)
	sync.mutex_lock(&st.ready_mu)
	nready := len(st.ready)
	sync.mutex_unlock(&st.ready_mu)
	return Stats{chunks = len(st.scene.chunks), inflight = len(st.inflight), reqs = nreq, ready = nready}
}

// --- internals ---

// drop_chunk frees a cell's render chunk, if it has one.
@(private)
drop_chunk :: proc(st: ^Streamer, cell: Form_ID) {
	if i, found := slice.linear_search(st.undecorated[:], cell); found {ordered_remove(&st.undecorated, i)}
	chunk, ok := &st.scene.chunks[cell]
	if !ok {return}
	release_chunk_assets(st.scene, chunk)
	delete_key(&st.scene.chunks, cell)
}

// (hole gamedb-for-streamer :tags (assets unclaimed) :sev wish) the streamer queries gamedb (cell_terrain, cell_base_textures, the LOD bakes); a streamer in Rust needs a C-ABI read view of gamedb or its own index.
// decorate gives up to `budget` new chunks their terrain, water and grass, nearest first, and
// requests their grass models. Terrain reads the instances, so it runs after populate.
@(private)
decorate :: proc(st: ^Streamer, budget: int) {
	t_start := time.tick_now()
	n := 0
	for ; n < budget && len(st.undecorated) > 0; n += 1 {
		cell := st.undecorated[0]
		ordered_remove(&st.undecorated, 0)
		chunk := &st.scene.chunks[cell]
		load_water(st.scene, st.db, chunk)
		load_terrain(st.scene, st.db, chunk)
		load_grass(st.scene, st.db, chunk)
		for b in chunk.grass {
			assetdb.model_acquire(&st.scene.cache, b.model_path)
			enqueue_model(st, b.model_path, extras = false) // grass: draw-only (no pick/collision)
		}
		// Each chunk's uploads are their own submits and SDL frees their staging only on copy
		// completion: a long unbudgeted run drains every few chunks or the host-visible heap runs out.
		if st.mode == .Loading && n % 8 == 7 {render.gpu_drain(st.scene.cache.r)}
	}
	if ms := time.duration_milliseconds(time.tick_since(t_start)); ms > 8 {
		log.infof("stream: decorated %d cells in %.1fms (%d still pending)", n, ms, len(st.undecorated))
	}
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
