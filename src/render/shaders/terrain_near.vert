#version 450
//
// Near-terrain vertex stage (terrain pivot). The streamed per-cell terrain meshes carry full
// geometric detail + real per-vertex normals (better than the CDLOD height-texture geometry), so
// near terrain keeps using them — but it's now TEXTURED by the shared terrain.frag (ground array +
// per-cell index + noise blend) instead of a single per-quadrant diffuse, so the near terrain
// blends seamlessly and matches the distant tier. This stage just transforms the world-space mesh
// and emits terrain.frag's varyings (no height-texture sampling — the verts already hold real Z).

layout(location = 0) in vec3 a_pos;     // world-space position (terrain verts are pre-placed)
layout(location = 1) in vec3 a_normal;  // world normal
layout(location = 2) in vec2 a_uv;      // unused (tiling derived from world position)
layout(location = 3) in vec4 a_tangent;

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;
    vec4 field; // xy = worldspace origin; zw = 1 / world extent (→ index-map UV)
    vec4 texel; // unused for near terrain
    vec4 cam;   // unused for near terrain (kept so the UBO layout matches terrain.vert)
    vec4 morph; // unused for near terrain (geomorph is CDLOD-only; near terrain is full-detail)
} ubo;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec3 v_worldpos;
layout(location = 3) out float v_cutoff;
layout(location = 4) out vec4 v_tangent;
layout(location = 5) out vec2 v_field_uv;
layout(location = 6) out vec2 v_inv_extent;

void main() {
    gl_Position = ubo.vp * vec4(a_pos, 1.0);
    v_normal = a_normal;
    v_uv = a_pos.xy / 512.0; // ground tiles 8×/cell, matching the distant tier + the old near UVs
    v_worldpos = a_pos;
    v_cutoff = 0.0;
    v_tangent = a_tangent;
    v_field_uv = (a_pos.xy - ubo.field.xy) * ubo.field.zw;
    v_inv_extent = ubo.field.zw;
}
