package main

// Headless physics-cost probe (`--clutterprobe`): build the real Riverwood window's FULL collision
// — terrain + every static-object body + every movable-clutter dynamic hull, exactly as the game's
// build_instance_bodies does — with NO GPU/window, then step and watch for the solver blow-up the
// in-game log exposed (dynamic clutter spawned interpenetrating static geometry → flung to Z≈13k →
// step time explodes to hundreds of ms). Reports body counts, per-step max ms, and how many dynamic
// bodies escaped to absurd heights (the blow-up signature). Sources collision from nif.parse_collision
// so it needs no renderer. Set the radius with a trailing int arg (default 4, matching the ~81-chunk
// in-game window).

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../formats/nif"
import "../gamedb"
import smath "../math"
import "../physics"
import "../settings"
import "../vfs"
import "../world"

when DEVTOOLS {
	// Dynamic bodies are built with the REAL world.dyn_sub (one collision shape → a body-local
	// Dyn_Shape), so the probe builds the SAME per-bhkRigidBody compounds the game does — it used
	// to carry a forked copy that could drift (cleanup.md 1.2).

	@(private = "file")
	matp :: proc(m: smath.Mat4, p: [3]f32) -> [3]f32 {
		v := m * [4]f32{p.x, p.y, p.z, 1}
		return {v.x, v.y, v.z}
	}

	@(private = "file")
	mat_scale :: proc(m: smath.Mat4) -> f32 {
		return smath.length3({m[0, 0], m[1, 0], m[2, 0]})
	}

	@(private = "file")
	box_corners :: proc(m: smath.Mat4, h: [3]f32, out: ^[dynamic][3]f32) {
		for sx in ([2]f32{-1, 1}) {
			for sy in ([2]f32{-1, 1}) {
				for sz in ([2]f32{-1, 1}) {
					append(out, matp(m, {h.x * sx, h.y * sy, h.z * sz}))
				}
			}
		}
	}

	run_clutter_probe :: proc(cfg: ^settings.Config) {
		if slice.contains(os.args, "hingetest") {run_hinge_test(cfg);return}
		R := 4
		if len(os.args) >= 3 {
			if n, ok := strconv.parse_int(os.args[2]); ok && n > 0 {R = n}
		}
		for a in os.args {if a == "ccd" {physics.clutter_ccd = true;log.info("--clutterprobe: clutter CCD ON")}}
		for a in os.args {if a == "boxify" {physics.dyn_boxify = true;log.info("--clutterprobe: dynamic hulls → OBB boxes")}}
		for a in os.args {
			if strings.has_prefix(a, "cr=") {
				if v, ok := strconv.parse_f64(a[3:]); ok {physics.convex_radius = f32(v);log.infof("--clutterprobe: convex_radius = %.2f units", v)}
			}
		}
		for a in os.args {
			if strings.has_prefix(a, "aecos=") {
				if v, ok := strconv.parse_f64(a[6:]); ok {physics.mesh_active_edge_cos = f32(v);log.infof("--clutterprobe: mesh active-edge cos = %.2f", v)}
			}
		}
		// `worldverts` = the OLD behaviour (static mesh/hull verts in world space at an origin-0 body).
		// Default now REBASES each static body to its ref origin (local verts, f64 body position) so the
		// narrow-phase runs at small magnitude instead of ~45000.
		world_verts := false
		for a in os.args {if a == "worldverts" {world_verts = true;log.info("--clutterprobe: static verts in WORLD space (origin-0 bodies)")}}
		src := resolve_source(cfg)
		if src == "" {log.error("--clutterprobe: no valid install configured");return}
		v := mount_game(src)
		defer vfs.destroy(&v)
		db, ok := load_gamedb(src)
		if !ok {log.error("--clutterprobe: no Skyrim.esm");return}
		defer gamedb.destroy(&db)
		phys, pok := physics.world_create()
		if !pok {log.error("--clutterprobe: physics init failed");return}
		defer {physics.world_destroy(&phys);physics.shutdown()}

		wfid, wok := gamedb.find_world(&db, "Tamriel")
		if !wok {log.error("--clutterprobe: Tamriel not found");return}
		RGX :: 5
		RGY :: -11

		dyn := make([dynamic]physics.Body, 0, 1024)
		dyn_model := make([dynamic]string, 0, 1024) // parallel to `dyn`: each hull's model (culprit id)
		defer delete(dyn)
		nstatic, ndyn_shapes := 0, 0
		total_tris, max_tris := 0, 0
		max_tris_path := ""
		max_hull := f32(0)
		max_hull_path := ""
		big_hulls := 0
		G :: 33
		tbuild := time.tick_now()
		for gy in RGY - R ..= RGY + R {
			for gx in RGX - R ..= RGX + R {
				cid, cok := gamedb.cell_at(&db, wfid, i32(gx), i32(gy))
				if !cok {continue}
				if heights, hok := gamedb.cell_terrain(&db, cid); hok {
					verts, _, _ := world.build_terrain_verts(heights, i32(gx), i32(gy), context.temp_allocator)
					ox, oy := f32(gx) * 4096, f32(gy) * 4096
					pts := make([][3]f32, len(verts), context.temp_allocator)
					for vv, i in verts {pts[i] = {vv.pos.x - ox, vv.pos.y - oy, vv.pos.z}}
					idx := make([dynamic]u32, 0, 32 * 32 * 6, context.temp_allocator)
					for y in 0 ..< 32 {
						for x in 0 ..< 32 {
							a := u32(y * G + x);b := u32(y * G + x + 1)
							c := u32((y + 1) * G + x);d := u32((y + 1) * G + x + 1)
							append(&idx, a, b, c, b, d, c)
						}
					}
					if physics.add_static_mesh(&phys, pts, idx[:], {ox, oy, 0}) != 0 {nstatic += 1}
				}

				for r in gamedb.refs_of(&db, cid) {
					if r.disabled {continue}
					modl, mok := gamedb.model_of(&db, r.base)
					if !mok || modl == "" {continue}
					full := strings.concatenate({"meshes\\", modl}, context.temp_allocator)
					data, dok := vfs.read(&v, full, context.temp_allocator)
					if !dok {continue}
					h, hok := nif.parse_header(data, context.temp_allocator)
					if !hok {continue}
					col := nif.parse_collision(data, &h, context.temp_allocator)
					wm0 := smath.trs(r.pos, r.rot, r.scale)
					// Phase A: one dynamic body per MOVABLE bhkRigidBody (exact primitives) — mirrors
					// world/collision.odin. Built before the static pass so its shapes are excluded there.
					for body, bi in col.bodies {
						if !body.movable {continue}
						subs := make([dynamic]physics.Dyn_Shape, 0, 8, context.temp_allocator)
						for sh in col.shapes {
							if sh.body == bi {world.dyn_sub(&subs, wm0, r.pos, sh)}
						}
						if len(subs) == 0 {continue}
						ndyn_shapes += 1
						blo := [3]f32{max(f32), max(f32), max(f32)}
						bhi := [3]f32{min(f32), min(f32), min(f32)}
						for sub in subs {
							if sub.kind == .Hull {
								for p in sub.points {blo = linalg.min(blo, p);bhi = linalg.max(bhi, p)}
							} else {
								e := sub.half if sub.kind == .Box else [3]f32{sub.radius, sub.radius, sub.radius}
								blo = linalg.min(blo, sub.pos - e);bhi = linalg.max(bhi, sub.pos + e)
							}
						}
						ext := smath.length3(smath.Vec3(bhi) - smath.Vec3(blo))
						if ext > max_hull {max_hull = ext;max_hull_path = modl}
						if ext > 500 {big_hulls += 1}
						log.infof("  DYNBODY pos=(%.0f,%.0f,%.0f) ext=%.0f nsub=%d model=%s", r.pos.x, r.pos.y, r.pos.z, ext, len(subs), modl)
						if b := physics.add_dynamic_body(&phys, subs[:], r.pos); b != 0 {append(&dyn, b);append(&dyn_model, strings.clone(modl))}
					}
					// Static shapes (fixed bodies) → one static body each; movable shapes built above.
					for sh in col.shapes {
						if sh.movable {continue}
						if !nif.layer_is_solid(sh.layer) {continue}
						wm := wm0 * sh.transform
						s := mat_scale(wm)
						b: physics.Body
						switch sh.kind {
						case .Mesh:
							skip := false
							for a in os.args {if a == "nomesh" {skip = true}}
							if skip {continue}
							tris := len(sh.indices) / 3
							total_tris += tris
							if tris > max_tris {max_tris = tris;max_tris_path = modl}
							o := [3]f32{0, 0, 0} if world_verts else r.pos
							pts := make([][3]f32, len(sh.vertices), context.temp_allocator)
							for p, i in sh.vertices {q := matp(wm, p);pts[i] = {q.x - o.x, q.y - o.y, q.z - o.z}}
							two := true
							for a in os.args {if a == "onesided" {two = false}}
							b = physics.add_static_mesh(&phys, pts, sh.indices, origin = o, two_sided = two)
						case .Convex:
							o := [3]f32{0, 0, 0} if world_verts else r.pos
							pts := make([][3]f32, len(sh.vertices), context.temp_allocator)
							for p, i in sh.vertices {q := matp(wm, p);pts[i] = {q.x - o.x, q.y - o.y, q.z - o.z}}
							b = physics.add_static_hull(&phys, pts, origin = o, margin = sh.radius * s)
						case .Box:
							o := [3]f32{0, 0, 0} if world_verts else r.pos
							corners := make([dynamic][3]f32, 0, 8, context.temp_allocator)
							box_corners(wm, sh.half_extents, &corners)
							for i in 0 ..< len(corners) {corners[i] -= o}
							b = physics.add_static_hull(&phys, corners[:], origin = o)
						case .Sphere:
							b = physics.add_static_sphere(&phys, matp(wm, {0, 0, 0}), sh.radius * s)
						case .Capsule:
							b = physics.add_static_capsule(&phys, matp(wm, sh.point_a), matp(wm, sh.point_b), sh.radius * s)
						}
						if b != 0 {nstatic += 1}
					}
					free_all(context.temp_allocator)
				}
			}
		}
		// Experiment: a big penetration tolerance so a slightly-embedded body rests (sleeps) instead of
		// jittering forever. `slop=<units>` arg overrides (default keeps world_create's unit-scaled value).
		for a in os.args {
			if strings.has_prefix(a, "slop=") {
				if s, ok := strconv.parse_f64(a[5:]); ok {
					physics.set_penetration_slop(&phys, f32(s))
					log.infof("--clutterprobe: penetrationSlop set to %.1f units", s)
				}
			}
			if strings.has_prefix(a, "spec=") {
				if s, ok := strconv.parse_f64(a[5:]); ok {
					physics.set_speculative(&phys, f32(s))
					log.infof("--clutterprobe: speculativeContactDistance set to %.3f units", s)
				}
			}
			if strings.has_prefix(a, "iters=") { // iters=V,P  (velocity,position solver steps; defaults 10,2)
				parts := strings.split(a[6:], ",", context.temp_allocator)
				if len(parts) == 2 {
					vv, _ := strconv.parse_int(parts[0])
					pp, _ := strconv.parse_int(parts[1])
					physics.set_solver_iterations(&phys, u32(vv), u32(pp))
					log.infof("--clutterprobe: solver iterations set to %d/%d", vv, pp)
				}
			}
		}
		physics.optimize_broadphase(&phys)
		log.infof(
			"--clutterprobe: R=%d (%d cells), %d static bodies, %d dynamic clutter bodies (built in %.1fs)",
			R, (2 * R + 1) * (2 * R + 1), nstatic, len(dyn), time.duration_seconds(time.tick_since(tbuild)),
		)
		log.infof("--clutterprobe: static MESH triangles: %d total, biggest single = %d (%s)", total_tris, max_tris, max_tris_path)
		log.infof("--clutterprobe: dynamic HULLS: biggest extent = %.0f units (%s); %d hulls > 500 units wide", max_hull, max_hull_path, big_hulls)

		worst :: proc(w: ^physics.World, n: int) -> (worst_ms, avg_ms: f64, at: int) {
			total := 0.0
			for i in 1 ..= n {
				t := time.tick_now()
				physics.step(w, 1.0 / 60.0)
				ms := time.duration_milliseconds(time.tick_since(t))
				total += ms
				if ms > worst_ms {worst_ms = ms;at = i}
			}
			return worst_ms, total / f64(n), at
		}
		flung :: proc(w: ^physics.World, dyn: []physics.Body, models: []string) -> (n: int, maxz: f32) {
			maxz = -1e9
			for b, i in dyn {
				z := physics.body_position(w, b).z
				if z > maxz {maxz = z}
				if z > 6000 {
					n += 1
					log.infof("  FLUNG body %d z=%.0f model=%s", i, z, models[i])
				}
			}
			return
		}

		// Phase 1 — LOAD: clutter spawns ASLEEP now, so stepping should be quiet (no mass-settle blow-up
		// and nothing flung to the sky).
		lw, la, lat := worst(&phys, 300)
		lf, lz := flung(&phys, dyn[:], dyn_model[:])
		log.infof("--clutterprobe: LOAD worst %.1f ms avg %.2f (@%d); %d/%d flung >z6000 (max z=%.0f)", lw, la, lat, lf, len(dyn), lz)

		// Phase 2 — SHOVE: wake EVERY dynamic body, then step 10s and watch the active-body count. If
		// bodies never return to sleep, the active set (and step cost) accumulates across shoves — the
		// in-game "1.7s after a few H presses" signature. Log the step-ms + active curve; then report how
		// many never slept and whether they're flung to the sky (falling forever) or stuck near the ground
		// (penetration jitter).
		// Settle-timeout test: track per-body active frames; a body active > ~1.5s but moving < 30 u/s is
		// stuck jittering → force-sleep it (this is the candidate fix). Set SETTLE=0 via arg to disable.
		// Phase 2 — reproduce the ALVOR'S PORCH case: repeatedly shove ONE small local cluster (the
		// clutter hotspot in Riverwood is Alvor's forge) and watch whether the cost GROWS jolt-over-jolt
		// as the items get driven into the forge/house collision. Find the densest cluster = the body with
		// the most neighbours within 400 units; shove that group 20×, stepping 3s between, logging worst
		// step + how far the group has drifted from its start (into geometry?).
		pos := make([][3]f32, len(dyn))
		for b, i in dyn {pos[i] = physics.body_position(&phys, b)}
		defer delete(pos)
		// Riverwood VILLAGE ground level (Alvor's forge) — exclude the mountain/sky clutter (z≈13000,
		// which just slides down slopes) so we find the village cluster the user is shoving.
		center := -1
		best := 0
		for i in 0 ..< len(dyn) {
			if abs(pos[i].z) > 1000 {continue} // skip mountain/high clutter
			n := 0
			for j in 0 ..< len(dyn) {
				if abs(pos[j].z) <= 1000 && smath.length3(smath.Vec3(pos[i]) - smath.Vec3(pos[j])) < 500 {n += 1}
			}
			if n > best {best = n;center = i}
		}
		if center < 0 {center = 0}
		cluster := make([dynamic]int, 0, 16)
		defer delete(cluster)
		for j in 0 ..< len(dyn) {
			if smath.length3(smath.Vec3(pos[center]) - smath.Vec3(pos[j])) < 500 {append(&cluster, j)}
		}
		log.infof("--clutterprobe: densest cluster = %d bodies near (%.0f,%.0f,%.0f)", len(cluster), pos[center].x, pos[center].y, pos[center].z)

		// JOLT PROFILER: kick ONE body (the whole cluster overflows the sample buffer) and profile the
		// spike step. Writes profile_chart_shove.html with the per-phase call tree.
		physics.kick(&phys, dyn[cluster[0]], {200, 0, 350})
		physics.step(&phys, 1.0 / 60.0) // step 1: body moves into contact (cheap)
		physics.profile_next_frame() // begin the profiled frame
		t2 := time.tick_now()
		physics.step(&phys, 1.0 / 60.0) // step 2: the spike (fills the sample buffer)
		log.infof("  [profiled] single-body spike step: %.1f ms", time.duration_milliseconds(time.tick_since(t2)))
		physics.profile_dump("shove") // request dump…
		physics.profile_next_frame() // …which happens here (writes profile_chart_shove.html), then resets
		log.info("--clutterprobe: wrote Jolt profile → profile_chart_shove.html")
		for _ in 1 ..= 240 {physics.profile_next_frame();physics.step(&phys, 1.0 / 60.0)} // re-settle
		// The key metric: after waking the Alvor cluster, how many bodies stay ACTIVE forever (stuck
		// jitter) and what's the SUSTAINED avg step cost they impose every frame (the 16-fps culprit).
		// `sleep=V,T` sets aggressive sleep thresholds to test whether that parks the jitterers.
		for a in os.args {
			if strings.has_prefix(a, "sleep=") {
				parts := strings.split(a[6:], ",", context.temp_allocator)
				if len(parts) == 2 {
					vv, _ := strconv.parse_f64(parts[0])
					tt, _ := strconv.parse_f64(parts[1])
					physics.set_sleep(&phys, f32(vv), f32(tt))
					log.infof("--clutterprobe: sleep threshold set to %.0f u/s over %.2fs", vv, tt)
				}
			}
		}
		// PENETRATION TEST: activate the cluster with ZERO velocity, step once. A body resting cleanly on
		// a surface stays ~0; a body spawned INSIDE static collision is violently ejected (speed jumps to
		// hundreds/thousands u/s). This tells us if the clutter is deeply penetrating the building = the
		// "collisions resolved wrong / bad state" you suspected.
		for j in cluster {physics.kick(&phys, dyn[j], {0, 0, 0})} // activate at rest
		physics.step(&phys, 1.0 / 60.0)
		maxspeed, nfast := f32(0), 0
		for j in cluster {
			s := physics.body_speed(&phys, dyn[j])
			if s > maxspeed {maxspeed = s}
			if s > 200 {nfast += 1}
		}
		log.infof(
			"--clutterprobe: PENETRATION TEST — activated %d bodies at REST, after 1 step: max speed %.0f u/s, %d ejected >200 u/s (high = spawned inside collision)",
			len(cluster), maxspeed, nfast,
		)
		// Then the sustained-cost measurement (worst + avg over 5s).
		for j in cluster {physics.kick(&phys, dyn[j], {200, 0, 350})}
		sworst, savg, _ := worst(&phys, 300)
		stuck := 0
		for j in cluster {if physics.body_active(&phys, dyn[j]) {stuck += 1}}
		log.infof("--clutterprobe: cluster of %d — after 5s: %d STILL ACTIVE; worst %.1f ms, sustained avg %.2f ms/step", len(cluster), stuck, sworst, savg)

		// Phase 3 — STRESS: fling EVERY dynamic body hard in a spread of horizontal directions (sim: the
		// in-game H-shove driving clutter INTO whatever building/wall is next to it). This reproduces the
		// real-game hitch that the local-cluster shove above misses: a body embeds a building trimesh →
		// convex-vs-mesh EPA storm (the profiler's sCollideConvexVsMesh + GetPenetrationDepthStepEPA). Then
		// report the worst step + the models of the bodies still thrashing, so a fix can be measured here.
		// PER-BODY culprit hunt (`perbody` arg): wake ONE dynamic body at a time (all others asleep),
		// step once, measure THAT step's cost = the body's solo convex-vs-local-static-mesh cost. Ranks
		// the most expensive → names the specific model/mesh pairing behind the storm (a data bug shows as
		// a few outliers; a distributed cost shows as uniform). Deactivates each afterward to isolate.
		if slice.contains(os.args, "perbody") {
			for b in dyn {physics.deactivate(&phys, b)}
			physics.step(&phys, 1.0 / 60.0) // let the deactivations take
			Cost :: struct {ms: f64, i: int}
			costs := make([]Cost, len(dyn))
			for b, i in dyn {
				// Drive this ONE body into its local geometry over 120 steps (others asleep) and take its
				// WORST step — the storm builds over frames as a body drives deeper, so a single step misses it.
				worst_b := 0.0
				for f in 1 ..= 120 {
					physics.kick(&phys, b, {200, 200, 0}) // keep pushing it into whatever's nearby
					t := time.tick_now()
					physics.step(&phys, 1.0 / 60.0)
					ms := time.duration_milliseconds(time.tick_since(t))
					if ms > worst_b {worst_b = ms}
				}
				costs[i] = {worst_b, i}
				physics.deactivate(&phys, b)
				physics.step(&phys, 1.0 / 60.0) // settle the deactivation before the next body
			}
			slice.sort_by(costs, proc(a, b: Cost) -> bool {return a.ms > b.ms})
			log.info("--clutterprobe: PER-BODY solo step cost (top 15):")
			for k in 0 ..< min(15, len(costs)) {
				c := costs[k]
				p := physics.body_position(&phys, dyn[c.i])
				log.infof("  %6.1f ms  pos=(%.0f,%.0f,%.0f) model=%s", c.ms, p.x, p.y, p.z, dyn_model[c.i])
			}
			return
		}

		// `sub=N` runs N collision substeps per step (shallower penetration per substep). `fling=V` sets
		// the fling speed (default 600 u/s ≈ the in-game H-shove driving clutter into walls).
		nsub := 1
		fling := f32(600)
		for a in os.args {
			if strings.has_prefix(a, "sub=") {if n, ok := strconv.parse_int(a[4:]); ok {nsub = n}}
			if strings.has_prefix(a, "fling=") {if v, ok := strconv.parse_f64(a[6:]); ok {fling = f32(v)}}
		}
		for b, i in dyn {
			ang := f32(i) * 2.399963 // golden angle → directions spread over all clutter
			physics.kick(&phys, b, {math.cos(ang) * fling, math.sin(ang) * fling, 250})
		}
		sw, sa := 0.0, 0.0
		sw_at := 0
		for f in 1 ..= 300 {
			t := time.tick_now()
			physics.step(&phys, 1.0 / 60.0, nsub)
			ms := time.duration_milliseconds(time.tick_since(t))
			sa += ms
			if ms > sw {sw = ms;sw_at = f}
		}
		nact, fell := 0, 0
		for b, i in dyn {
			p := physics.body_position(&phys, b)
			// Riverwood ground ≈ -100; legit high clutter is +13000. A body that ended up far BELOW the
			// world (and below its spawn) tunneled through the single-sided floor mesh.
			if p.z < -1000 && p.z < pos[i].z - 500 {fell += 1}
			if physics.body_active(&phys, b) {
				nact += 1
				if nact <= 8 {log.infof("  STRESS-ACTIVE pos=(%.0f,%.0f,%.0f) model=%s", p.x, p.y, p.z, dyn_model[i])}
			}
		}
		log.infof("--clutterprobe: STRESS flung all %d — worst %.1f ms (@%d), avg %.2f ms/step, %d active, %d FELL THROUGH floor", len(dyn), sw, sw_at, sa / 300, nact, fell)
	}

	@(private = "file")
	matdir :: proc(m: smath.Mat4, d: [3]f32) -> [3]f32 {
		v := m * [4]f32{d.x, d.y, d.z, 0}
		return {v.x, v.y, v.z}
	}

	// run_hinge_test (`--clutterprobe hingetest`): headless Phase-B validation. Load the Riverwood sign,
	// build its 3 rigid bodies (static mount + dynamic ring + dynamic board) and 2 bhkLimitedHingeConstraints
	// exactly as the game does, let it hang under gravity, then shove the board. A working hinge keeps the
	// board BOUND to the assembly (its distance from the static-mount anchor stays bounded — a broken joint
	// sends it to thousands) while it SWINGS. Exercises add_hinge + the constraint math without a GPU.
	@(private = "file")
	run_hinge_test :: proc(cfg: ^settings.Config) {
		src := resolve_source(cfg)
		if src == "" {log.error("hingetest: no valid install configured");return}
		v := mount_game(src)
		defer vfs.destroy(&v)
		phys, pok := physics.world_create()
		if !pok {log.error("hingetest: physics init failed");return}
		defer {physics.world_destroy(&phys);physics.shutdown()}

		path := "meshes\\Clutter\\Signage\\Riverwood\\SignRiverwoodSleepingGiantInn01.nif"
		for a in os.args {
			if a == "trader" {path = "meshes\\Clutter\\Signage\\Riverwood\\SignRiverwoodRiverwoodTrader01.nif"}
			if a == "blacksmith" {path = "meshes\\Clutter\\Signage\\Riverwood\\SignRiverwoodRiverwoodBlacksmith01.nif"}
		}
		data, dok := vfs.read(&v, path, context.temp_allocator)
		if !dok {log.errorf("hingetest: can't read %s", path);return}
		h, hok := nif.parse_header(data, context.temp_allocator)
		if !hok {log.error("hingetest: header parse failed");return}
		col := nif.parse_collision(data, &h, context.temp_allocator)
		log.infof("hingetest: %d bodies, %d shapes, %d constraints", len(col.bodies), len(col.shapes), len(col.constraints))

		origin := [3]f32{0, 0, 1000}
		wm0 := smath.trs(origin, {0, 0, 0}, 1)
		body_ids := make([]physics.Body, len(col.bodies), context.temp_allocator)
		for body, bi in col.bodies {
			if body.movable {
				subs := make([dynamic]physics.Dyn_Shape, 0, 8, context.temp_allocator)
				for sh in col.shapes {if sh.body == bi {world.dyn_sub(&subs, wm0, origin, sh)}}
				if len(subs) > 0 {
					if b := physics.add_dynamic_body(&phys, subs[:], origin); b != 0 {body_ids[bi] = b}
				}
			} else {
				for sh in col.shapes {
					if sh.body != bi || !nif.layer_is_solid(sh.layer) {continue}
					wm := wm0 * sh.transform
					s := mat_scale(wm)
					b: physics.Body
					switch sh.kind {
					case .Capsule:
						b = physics.add_static_capsule(&phys, matp(wm, sh.point_a), matp(wm, sh.point_b), sh.radius * s)
					case .Convex, .Mesh:
						pts := make([][3]f32, len(sh.vertices), context.temp_allocator)
						for p, i in sh.vertices {pts[i] = matp(wm, p)}
						if sh.kind == .Mesh {b = physics.add_static_mesh(&phys, pts, sh.indices)} else {b = physics.add_static_hull(&phys, pts, margin = sh.radius * s)}
					case .Box:
						corners := make([dynamic][3]f32, 0, 8, context.temp_allocator)
						box_corners(wm, sh.half_extents, &corners)
						b = physics.add_static_hull(&phys, corners[:])
					case .Sphere:
						b = physics.add_static_sphere(&phys, matp(wm, {0, 0, 0}), sh.radius * s)
					}
					if b != 0 && body_ids[bi] == 0 {body_ids[bi] = b}
				}
			}
		}

		nh := 0
		anchor := origin
		board_bi, best := -1, f32(0)
		for c in col.constraints {
			a := body_ids[c.body_a];b := body_ids[c.body_b]
			if a == 0 || b == 0 {continue}
			wp := matp(wm0, c.pivot)
			wa := smath.normalize3(matdir(wm0, c.axis))
			wperp := smath.normalize3(matdir(wm0, c.perp))
			if physics.add_hinge(&phys, a, b, wp, wa, wperp, c.min_angle, c.max_angle, c.max_friction, c.limited) != nil {nh += 1}
			if !col.bodies[c.body_b].movable {anchor = wp} // the hinge to the static mount = the top anchor
		}
		for body, bi in col.bodies {if body.movable && body.mass > best && body_ids[bi] != 0 {best = body.mass;board_bi = bi}}
		log.infof("hingetest: built %d hinges; board=body%d (mass %.0f)", nh, board_bi, best)
		if nh == 0 || board_bi < 0 {log.error("hingetest: FAILED to build hinges/board");return}
		board := body_ids[board_bi]
		physics.optimize_broadphase(&phys)

		// Wake + hang under gravity, then shove and watch the board's distance from the top anchor.
		physics.kick(&phys, board, {0, 0, 0})
		for _ in 1 ..= 180 {physics.step(&phys, 1.0 / 60.0)}
		p0 := physics.body_position(&phys, board)
		d0 := smath.length3(smath.Vec3(p0) - smath.Vec3(anchor))
		physics.kick(&phys, board, {400, 0, 100})
		dmin, dmax, moved := d0, d0, f32(0)
		for _ in 1 ..= 300 {
			physics.step(&phys, 1.0 / 60.0)
			p := physics.body_position(&phys, board)
			d := smath.length3(smath.Vec3(p) - smath.Vec3(anchor))
			dmin = min(dmin, d);dmax = max(dmax, d)
			moved = max(moved, smath.length3(smath.Vec3(p) - smath.Vec3(p0)))
		}
		bound := dmax < d0 + 200 // sign is ~280u tall; a broken hinge sends the board thousands away
		swung := moved > 5
		verdict := "PASS" if (bound && swung) else "FAIL"
		log.infof("hingetest: board anchor-dist rest=%.0f during-shove[%.0f..%.0f] swing=%.0f", d0, dmin, dmax, moved)
		log.infof("hingetest: %s — board %s, swing=%.0fu", verdict, "STAYS BOUND" if bound else "FLEW OFF", moved)

		// HARD-SHOVE stability: kick EVERY movable body repeatedly (the "shoved too hard" case) and watch
		// for a constraint blow-up — a body flung absurdly far or a NaN. `hard` uses an extreme 2000 u/s;
		// default is the realistic in-game shove speed (~460). Logs the FIRST body to go NaN + its round.
		shove := f32(460)
		for a in os.args {if a == "hard" {shove = 2000}}
		worst_far, nan_body, nan_round := f32(0), -1, -1
		// SAME direction every round — the realistic worst case (player shoves the same sign repeatedly),
		// which pumps a resonance into a deep chain (this is what NaN'd the Trader before the stability fix).
		for round in 1 ..= 12 {
			for b in body_ids {
				if b != 0 {physics.kick(&phys, b, {shove, shove * 0.4, shove * 0.3})}
			}
			for _ in 1 ..= 30 {physics.step(&phys, 1.0 / 60.0)} // shorter settle → more pumping
			for b, bi in body_ids {
				if b == 0 {continue}
				p := physics.body_position(&phys, b)
				if (p.x != p.x || p.y != p.y || p.z != p.z) && nan_body < 0 {nan_body = bi;nan_round = round}
				far := smath.length3(smath.Vec3(p) - smath.Vec3(anchor))
				if far == far {worst_far = max(worst_far, far)}
			}
		}
		exploded := nan_body >= 0 || worst_far > 2000
		if nan_body >= 0 {
			log.infof("hingetest: HARD-SHOVE (%.0f u/s) EXPLODED — body%d went NaN at round %d (movable=%v mass=%.0f)", shove, nan_body, nan_round, col.bodies[nan_body].movable, col.bodies[nan_body].mass)
		} else {
			log.infof("hingetest: HARD-SHOVE (%.0f u/s) %s — worst body %.0fu from anchor", shove, "FLUNG" if exploded else "stable", worst_far)
		}
	}
} // when DEVTOOLS
