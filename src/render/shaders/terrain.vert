#version 450
//
// CDLOD terrain vertex stage (terrain pivot, phase 1). A single reusable unit-grid patch is
// drawn INSTANCED, once per quadtree node; each instance places + scales the patch over a
// square of world, and the heightfield is sampled from a texture HERE in the vertex shader
// (set 0) rather than baked into per-cell vertex buffers. Outputs the exact varying set the
// shared mesh.frag consumes (normal/uv/worldpos/cutoff/tangent), so terrain reuses the full
// lighting + shadow path for free. CDLOD GEOMORPH (this phase): as the camera nears the distance
// where a patch's parent node takes over, each vertex blends toward the next-coarser grid so the
// shape slides continuously into fidelity (no LOD pop) and odd vertices collapse onto the coarse
// edge (crack-free with one-level-coarser neighbours). Height/normal are sampled at the MORPHED xy.

// PATCH_GRID quads per patch side — must match TERR_PATCH_GRID in terrain_cdlod.odin. Used to find
// each vertex's offset to the next-coarser (even-index) grid for the morph.
#define PATCH_GRID 32.0

// slot 0: the unit grid patch. Reuses the Mesh_Vertex layout (loc 0-3); only a_pos.xy is read
// (the grid coordinate in [0,1]). slot 1: per-instance placement.
layout(location = 0) in vec3 a_pos;     // grid coord: a_pos.xy in [0,1], rest unused
layout(location = 4) in vec4 a_inst;    // x,y = world origin; z = patch size (world units); w = morph_end

layout(set = 0, binding = 0) uniform sampler2D u_height; // R32F world-Z heightfield

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;
    vec4 field; // xy = world origin of the height texture; zw = 1 / world extent (→ UV)
    vec4 texel; // xy = 1 / texture dims (one texel in UV); z = world units per texel; w = height drop
    vec4 cam;   // xyz = camera world pos (xy = geomorph distance); w = height-drop fade band
    vec4 morph; // x = start ratio (of morph_end); y = strength (1 = crack-free); z = distance scale; w = drop fade start
} ubo;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_worldpos;
layout(location = 2) out vec2 v_field_uv;   // 0..1 over the worldspace (index-map lookup)
layout(location = 3) out vec2 v_inv_extent; // 1 / world extent (world→UV scale for the frag jitter)
layout(location = 4) out float v_fade;       // fade-in; the field never fades

float h_at(vec2 uv) { return texture(u_height, uv).r; }

void main() {
    vec2 world_xy = a_inst.xy + a_pos.xy * a_inst.z;

    // CDLOD geomorph: morphK ramps 0→1 across this patch's active distance band so the vertex is
    // fully collapsed onto the coarse grid exactly when the parent node would replace it (a_inst.w =
    // morph_end = the parent's switch distance). Distance is 2D (matches the quadtree XY selection),
    // so flying high keeps the ground below detailed.
    float dist = distance(ubo.cam.xy, world_xy);
    // morph.z scales the morph-zone distance: 1.0 = morph completes exactly at the LOD switch
    // (crack-free); >1 pushes it to start farther out (more gradual, slight pop at the switch);
    // <1 finishes it before the switch (snappier).
    float morph_end = a_inst.w * ubo.morph.z;
    float morph_start = morph_end * ubo.morph.x;
    float morphK = clamp((dist - morph_start) / max(morph_end - morph_start, 1e-3), 0.0, 1.0);
    morphK *= ubo.morph.y;
    // frac_part = offset from this fine vertex to its even-index (coarser) neighbour, in [0,1] patch
    // units; odd grid lines slide onto the previous even line, even lines stay put. Scale to world.
    vec2 frac_part = fract(a_pos.xy * (PATCH_GRID * 0.5)) * (2.0 / PATCH_GRID);
    world_xy -= frac_part * a_inst.z * morphK;

    vec2 uv = (world_xy - ubo.field.xy) * ubo.field.zw;

    // Sink the field below true height so the full-detail NEAR terrain (lod-0 cells) wins where the
    // two overlap — but ONLY close to the camera, where that overlap exists. Fade the sink to zero
    // by the near-terrain edge (morph.w = fade start, cam.w = fade band) so DISTANT terrain reads at
    // true height; otherwise it sits ~drop below and distant water floats over it / shows the
    // per-cell water squares. The ramp happens UNDER the near terrain, so the bend stays hidden.
    float drop = ubo.texel.w * (1.0 - clamp((dist - ubo.morph.w) / max(ubo.cam.w, 1.0), 0.0, 1.0));
    float z = h_at(uv) - drop;

    vec3 world = vec3(world_xy, z);
    gl_Position = ubo.vp * vec4(world, 1.0);
    v_uv = world_xy / 4096.0; // distant tier tiles 1×/cell on purpose: the stretch reads as a soft,
    // blurry ground blend (kept deliberately coarse). Near terrain tiles finer (terrain_near.vert).
    v_worldpos = world;
    v_field_uv = uv; // reuse the height-texture UV: 0..1 over the worldspace
    v_inv_extent = ubo.field.zw;
    v_fade = 1.0;
}
