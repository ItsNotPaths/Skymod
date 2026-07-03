package world

// Baked distant-object LOD (the DynDOLOD-style tier). Per-cell distant-object instancing made the
// draw-call COUNT the bottleneck (objdraw hit ~150ms recording ~11k per-cell draws while the GPU
// sat idle). This bakes the WHOLE worldspace's distant objects ONCE at load, from gamedb directly
// (independent of the cell streamer — so there is NO per-frame or per-cell-stream rebuild churn,
// the thing that overloaded the iGPU): each LOD-eligible REFR's coarse MNAM mesh (or a tree's
// billboard) is placed in world space and merged, by QUAD + model, into one instance buffer.
// Drawing is then one instanced call per (visible quad, model) — a few hundred draws for the whole
// horizon instead of thousands. Every buffer uploads in ONE batched submit (never a submit per
// buffer). Meshes decode lazily on the streamer pool; the instance buffers are mesh-independent.
//
// The near transition: a quad fully inside the full-detail bubble is suppressed at draw (those
// cells already draw full meshes), so there's no double-draw — see draw_object_lod.

import "core:log"
import "core:math"

import "../assetdb"
import "../gamedb"
import smath "../math"
import "../render"

// Tunables (set from settings.txt via main; see object_lod_band / object_lod_quad there).
// BAND = which MNAM LOD slot every baked static uses (0 = LOD4 sharpest … 3 = LOD32 coarsest).
// QUAD = cells per baked quad edge; smaller = cleaner near-suppression but more draw calls.
OBJECT_LOD_BAND := 1
OBJECT_LOD_QUAD := i32(8)

// Cell_Span is one cell's contiguous sub-range of a Lod_Draw's merged instance buffer. The bake
// groups a buffer by cell (the bake loop is per-cell), so each cell's instances are a [first,+count)
// block — letting draw_object_lod render only the cells OUTSIDE the full-detail bubble for a quad
// that straddles it (the "skirt"), instead of the whole quad (double-render) or nothing (gap).
Cell_Span :: struct {
	cx, cy:    i32,
	first:     u32,
	count:     u32,
}

// Lod_Draw is one LOD model's merged placements within a quad: a static instance buffer (built at
// bake, reused every frame) + the model resolved LAZILY at draw (the buffer is just matrices) +
// per-cell spans into the buffer (for the near skirt; see Cell_Span).
Lod_Draw :: struct {
	model_path: string,
	model:      ^assetdb.Model,
	veg:        Veg_Kind,
	buf:        render.Obj_Instances,
	spans:      [dynamic]Cell_Span,
}

// Lod_Quad is one quad's merged distant objects: its quad grid coordinate (for near-suppression),
// a cull AABB, and one Lod_Draw per unique LOD model in the quad.
Lod_Quad :: struct {
	gx, gy: i32,
	lo, hi: smath.Vec3,
	draws:  [dynamic]Lod_Draw,
}

// lod_quad_div maps a cell grid coord to its quad coord (floor-div by OBJECT_LOD_QUAD). Shared by
// the object + water bakes so both use the SAME quad grid (consistent culling/suppression).
lod_quad_div :: proc(a: i32) -> i32 {
	q := a / OBJECT_LOD_QUAD
	if a % OBJECT_LOD_QUAD != 0 && a < 0 {q -= 1} // round toward -inf (OBJECT_LOD_QUAD > 0)
	return q
}

// lod_quad_key packs a quad coord into a map key.
lod_quad_key :: proc(qgx, qgy: i32) -> u64 {
	return (u64(u32(qgx)) << 32) | u64(u32(qgy))
}

// bake_object_lod builds the whole worldspace's distant-object LOD into per-quad merged buffers,
// once, from gamedb. Call after stream_init and on stream_retarget (new worldspace). No-op for a
// worldspace with no cells. Enqueues each LOD mesh path for off-thread decode (draw resolves them
// lazily, so the bake itself never blocks on a decode).
bake_object_lod :: proc(st: ^Streamer) {
	s := st.scene
	db := st.db
	clear_object_lod(s)

	// Gather: (quad, model) -> placements, plus a per-quad AABB and grid coord.
	QM :: struct {
		quad: u64,
		path: string,
	}
	Bucket :: struct {
		veg:   Veg_Kind,
		insts: [dynamic]render.Obj_Instance,
		spans: [dynamic]Cell_Span, // per-cell sub-ranges of insts (extended as each cell's refs append)
	}
	buckets := make(map[QM]Bucket, 4096, context.temp_allocator)
	qaabb := make(map[u64][2]smath.Vec3, 1024, context.temp_allocator)
	qcoord := make(map[u64][2]i32, 1024, context.temp_allocator)

	// Size cull: drop objects too small to matter at distance (same thresholds as the per-cell path).
	obj_min := OBJ_MIN_RADIUS[clamp(OBJECT_LOD_BAND + 1, 0, len(OBJ_MIN_RADIUS) - 1)] * OBJ_LOD_FALLOFF
	tree_min := TREE_MIN_RADIUS[clamp(OBJECT_LOD_BAND + 1, 0, len(TREE_MIN_RADIUS) - 1)] * TREE_LOD_FALLOFF

	nrefs := 0
	for cid in gamedb.cells_of(db, st.world_fid) {
		cell, ok := gamedb.cell_by_formid(db, cid)
		if !ok || !cell.has_grid {
			continue // interiors / the persistent cell (its refs draw full via their grid chunk when near)
		}
		qgx, qgy := lod_quad_div(cell.gx), lod_quad_div(cell.gy)
		key := lod_quad_key(qgx, qgy)
		for r in gamedb.refs_of(db, cid) {
			if gamedb.ref_effective_disabled(db, r) || r.base == XMARKER || r.base == XMARKER_HEADING {
				continue
			}
			min_r: f32
			lod_path, has_lod := gamedb.lod_model_of(db, r.base, OBJECT_LOD_BAND)
			if has_lod && !is_marker_path(lod_path) {
				min_r = obj_min
			} else {
				bb, is_bb := tree_billboard_for(s, db, r.base) // TREEs → prebaked billboard; else drop
				if !is_bb {
					continue
				}
				lod_path = bb
				min_r = tree_min
			}
			wr := gamedb.base_size(db, r.base) * r.scale
			if wr < min_r {
				continue
			}
			qm := QM{quad = key, path = lod_path}
			b, has := &buckets[qm]
			if !has {
				buckets[qm] = Bucket {
					veg   = veg_classify(lod_path),
					insts = make([dynamic]render.Obj_Instance, 0, 32, context.temp_allocator),
					spans = make([dynamic]Cell_Span, 0, 16, context.temp_allocator),
				}
				b = &buckets[qm]
			}
			// Extend this cell's span (cells are processed one at a time, so a cell's appends to a
			// bucket are contiguous → the last span is this cell's until we move to the next cell).
			if n := len(b.spans); n > 0 && b.spans[n - 1].cx == cell.gx && b.spans[n - 1].cy == cell.gy {
				b.spans[n - 1].count += 1
			} else {
				append(&b.spans, Cell_Span{cx = cell.gx, cy = cell.gy, first = u32(len(b.insts)), count = 1})
			}
			append(&b.insts, render.Obj_Instance{world = smath.trs(r.pos, r.rot, r.scale)})

			box, hasb := qaabb[key]
			if !hasb {
				box = {{max(f32), max(f32), max(f32)}, {min(f32), min(f32), min(f32)}}
			}
			box[0] = {min(box[0].x, r.pos.x - wr), min(box[0].y, r.pos.y - wr), min(box[0].z, r.pos.z - wr)}
			box[1] = {max(box[1].x, r.pos.x + wr), max(box[1].y, r.pos.y + wr), max(box[1].z, r.pos.z + wr)}
			qaabb[key] = box
			qcoord[key] = {qgx, qgy}
			nrefs += 1
		}
	}

	// Create the quad shells first, so the fill loop's &s.lod_quads[key] pointers stay valid (no
	// insert into s.lod_quads happens during the fill loop → no rehash).
	for key, box in qaabb {
		c := qcoord[key]
		s.lod_quads[key] = Lod_Quad{gx = c[0], gy = c[1], lo = box[0], hi = box[1]}
	}

	// Upload EVERY quad/model buffer in one batch (one command buffer + submit), enqueue decodes.
	batch := render.upload_begin(s.cache.r)
	nbuf := 0
	for qm, b in buckets {
		if len(b.insts) == 0 {
			continue
		}
		buf := render.upload_obj_instances_into(&batch, b.insts[:])
		quad := &s.lod_quads[qm.quad]
		spans := make([dynamic]Cell_Span, len(b.spans)) // scene-owned copy (bucket is temp); freed in clear_object_lod
		copy(spans[:], b.spans[:])
		append(&quad.draws, Lod_Draw{model_path = qm.path, veg = b.veg, buf = buf, spans = spans})
		assetdb.model_acquire(&s.cache, qm.path) // D1: the session-long LOD pin (released in clear_object_lod)
		enqueue_model(st, qm.path, extras = false) // draw-only: LOD meshes/billboards are never picked or cooked
		nbuf += 1
	}
	render.upload_end(&batch)
	log.infof(
		"object LOD: baked %d quads / %d model-buffers from %d refs (band %d, quad %d)",
		len(s.lod_quads), nbuf, nrefs, OBJECT_LOD_BAND, OBJECT_LOD_QUAD,
	)
}

// clear_object_lod releases every baked quad's GPU buffers and empties the quad map (teardown /
// worldspace change).
clear_object_lod :: proc(s: ^Scene) {
	for _, &q in s.lod_quads {
		for d in q.draws {
			assetdb.model_release(&s.cache, d.model_path) // D1: release the per-draw LOD pin
			render.release_obj_instances(s.cache.r, d.buf)
			delete(d.spans)
		}
		delete(q.draws)
	}
	clear(&s.lod_quads)
}

// draw_object_lod draws the baked distant-object quads, frustum-culled by quad AABB. Near transition
// is the HYBRID SKIRT (docs/live-state none — object-lod-near-double-render): per-quad each cell is
// classified against the full-detail bubble (Chebyshev `full_radius` of the camera cell), and
//   • quad fully INSIDE the bubble  → skipped entirely (those cells draw full meshes)
//   • quad fully OUTSIDE the bubble → drawn whole (one instanced draw per model — the cheap far path)
//   • quad STRADDLING the bubble    → drawn per-cell via the bake's spans, emitting only the cells
//                                     OUTSIDE the bubble (the skirt) — so no LOD twin over a full
//                                     mesh (double-render) and no missing distant objects (gap).
// Nothing is uploaded here — buffers are baked.
draw_object_lod :: proc(
	s: ^Scene,
	r: ^render.Renderer,
	vp: smath.Mat4,
	cam_pos: smath.Vec3,
	full_radius: int,
	wind: render.Wind = {},
	time: f32 = 0,
) {
	f := smath.frustum_from_vp(vp)
	pcx := i32(math.floor(cam_pos.x / CELL_SIZE))
	pcy := i32(math.floor(cam_pos.y / CELL_SIZE))
	fr := i32(full_radius)
	cell_in_bubble :: proc(cx, cy, pcx, pcy, fr: i32) -> bool {
		return cx >= pcx - fr && cx <= pcx + fr && cy >= pcy - fr && cy <= pcy + fr
	}
	for _, &q in s.lod_quads {
		if len(q.draws) == 0 {
			continue
		}
		qx0, qy0 := q.gx * OBJECT_LOD_QUAD, q.gy * OBJECT_LOD_QUAD
		qx1, qy1 := qx0 + OBJECT_LOD_QUAD - 1, qy0 + OBJECT_LOD_QUAD - 1
		// Quad fully inside the bubble → every cell is full-detail; skip (no LOD at all).
		if qx0 >= pcx - fr && qx1 <= pcx + fr && qy0 >= pcy - fr && qy1 <= pcy + fr {
			continue
		}
		if !smath.aabb_in_frustum(f, q.lo, q.hi) {
			continue
		}
		// Straddling = the quad's cell span overlaps the bubble at all. Such a quad draws per-cell
		// (skirt); a quad with no overlap draws whole.
		straddles :=
			qx1 >= pcx - fr && qx0 <= pcx + fr && qy1 >= pcy - fr && qy0 <= pcy + fr
		for &d in q.draws {
			if d.model == nil {
				d.model = assetdb.model_ptr(&s.cache, d.model_path)
				if d.model == nil {
					continue // mesh not decoded yet — pops in when the worker delivers it
				}
			}
			bw := veg_wind_for(d.veg, wind) // amplitude+speed+cap by vegetation type (0 = rigid)
			for sh in d.model.shapes {
				// The mesh IS Skyrim's prebaked LOD model for this band — drawn whole (index_count 0).
				if straddles {
					// Skirt: emit only the cells outside the bubble (the full-detail cells already
					// draw their meshes, so their LOD twin is suppressed per-cell).
					for sp in d.spans {
						if cell_in_bubble(sp.cx, sp.cy, pcx, pcy, fr) {
							continue
						}
						render.draw_obj(
							r,
							sh.mesh,
							d.buf,
							vp,
							sh.local,
							sh.tex,
							sh.alpha_cutoff,
							0,
							wind = bw,
							time = time,
							normal = sh.normal,
							mat = shape_mat(sh),
							first_instance = sp.first,
							inst_count = sp.count,
						)
					}
					continue
				}
				render.draw_obj(
					r,
					sh.mesh,
					d.buf,
					vp,
					sh.local,
					sh.tex,
					sh.alpha_cutoff,
					0,
					wind = bw,
					time = time,
					normal = sh.normal,
					mat = shape_mat(sh),
				)
			}
		}
	}
}
