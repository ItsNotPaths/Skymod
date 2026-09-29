package graphics

// Drawing the world. Main owns the window, the GPU device, the swapchain and the UI; each frame it
// hands this seam the device, the command buffer, the color target and the frame as plain data, and
// draws the UI over the target after. The built-in (app) is fullbright. A plugin replaces Table.draw.

import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_graphics"
VERSION :: u32(3)

Camera :: struct {
	pos:        [3]f32,
	view, proj: matrix[4, 4]f32, // proj is reversed-Z (far = 0)
}

// Ref is one placed ref in a loaded cell.
Ref :: struct {
	id, base: Form_ID,
	cell:     Form_ID,
	model:    u32, // model_path names it; 0 = none
	world:    matrix[4, 4]f32, // this frame's transform: a moving ref's blended pose
	hidden:   bool, // disabled, or hidden by a script
}

// Actor is one loaded actor's body: an upright capsule on its feet.
Actor :: struct {
	id, base:       Form_ID,
	feet:           [3]f32, // this frame's blended position
	radius, half_h: f32,
	dead:           bool,
}

// Cell is one loaded cell.
// (hole graphics-cell-data :tags (render unclaimed) :sev gap) a plugin gets a cell's ID and grid only: nothing hands it the LAND heights, textures or water of the cell, which only the built-in's scene holds.
Cell :: struct {
	id:       Form_ID,
	gx, gy:   i32, // exterior only
	interior: bool,
}

Visual_Kind :: enum u8 {
	Shader, // EFSH on `ref`
	Art,    // ARTO on `ref`, facing `facing`
	Impact, // IPDS at `ref`'s `node`
	Imod,   // IMAD on the screen
}

// Visual is one effect a script or magic started. Placed emitters are not visuals: they come with
// their refs. Draw it while its handle is in the frame; a new handle is a new start, and a visual on
// a ref that is not drawn is not drawn.
Visual :: struct {
	handle:   u32,
	kind:     Visual_Kind,
	form:     Form_ID, // the EFSH, ARTO, IPDS or IMAD record
	ref:      Form_ID, // the ref or actor it plays on; 0 = the screen
	facing:   Form_ID, // Art: the ref it faces (a beam's target)
	flags:    u32,     // Art: its visual effect's (Visual_Effect.flags): face target, attach to camera, inherit rotation
	node:     cstring, // Impact: the node it plays at; "" = the root
	pos:      [3]f32,  // Impact with ref 0: where it lands
	strength: f32,     // Imod
	cross:    bool,    // Imod: the cross-fade modifier; at most one is not fading out
	fade:     f32,     // Imod: seconds it ramps in after it starts and out before it ends
	age:      f32,     // seconds since it started
	left:     f32,     // seconds until it ends; 0 = until it is gone from the frame
}

// Host is what main answers; each proc gets `data` back. It reads no sim state: graphics runs while
// the sim ticks.
Host :: struct {
	data:       rawptr,
	refs:       proc "c" (data: rawptr, out: [^]Ref, cap: int) -> int, // the count; written only when it fits in cap
	model_path: proc "c" (data: rawptr, model: u32) -> cstring, // under meshes\
	read_file:  proc "c" (data: rawptr, path: cstring, out: [^]u8, cap: int) -> int, // the size, -1 = missing; written only when it fits in cap
	record:     proc "c" (data: rawptr, form: Form_ID, kind: plugin.Record_Kind, out: rawptr) -> bool, // see record
}

// record fills `out` with the record view of `form` (plugin/records.odin: the visual records, and
// any other); false when it has none. Spans in it last until the frame ends.
record :: proc "contextless" (h: ^Host, form: Form_ID, kind: plugin.Record_Kind, out: ^$T) -> bool {
	out.size = u32(size_of(T))
	return h.record(h.data, form, kind, out)
}

// (hole render-inputs-snapshot :tags (threading render unclaimed) :sev gap) the frame carries no game hour, weather and its transition (ws.weather), lighting template or interior lighting, which day-night and sky need. Wanted: the sim publishes these in the snapshot and main passes them here, never ws.clock or g.trav.
Frame :: struct {
	host:          Host,
	table:         ^Table,
	device:        rawptr, // ^SDL_GPUDevice
	cmd:           rawptr, // ^SDL_GPUCommandBuffer: record every pass here
	target:        rawptr, // ^SDL_GPUTexture in format `format`; fill all of it
	format:        u32, // SDL_GPUTextureFormat
	width, height: u32,
	camera:        Camera,
	time:          f32, // seconds since start
	interior:      bool, // the camera is in an interior cell
	first_person:  bool, // `player` is the camera's body: do not draw it over the view
	player:        Actor,
	actors:        plugin.Span(Actor), // all but the player
	cells:         plugin.Span(Cell),
	visuals:       plugin.Span(Visual),
}

Table :: struct {
	draw: proc "c" (f: ^Frame),
}
