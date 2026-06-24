#version 450
//
// General mesh vertex stage (ROADMAP B4; full-scene-lighting Phase A). Position + normal +
// UV in; the per-draw UBO (set 1, binding 0) carries the view-projection + model matrix, the
// alpha cutoff, and the vegetation wind. Lighting moved to PER-PIXEL (mesh.frag) under the
// per-frame lighting UBO, so this stage no longer computes N·L — it just transforms the
// normal + position into WORLD space and hands them across, with the UV + cutoff.
//
// WIND (ROADMAP vegetation): the same procedural sway as grass.vert — one GLOBAL wind
// direction/strength/speed (NOT per-instance directions) plus a per-draw phase drive a sine
// displacement whose amplitude scales with height above the model origin, so trunks/roots
// stay planted and canopies/tips move. strength 0 (every non-vegetation draw) leaves geometry
// exactly where vp·model places it. Isolated in sway() — the seam a future physics sim replaces.

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec2 a_uv;
layout(location = 3) in vec4 a_tangent; // xyz tangent + w bitangent handedness

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;        // view-projection
    mat4 model;     // world transform (also transforms normals)
    vec4 mtl;       // x = alpha cutoff (foliage cutouts)
    vec4 wind;      // xy = global wind direction; z = strength; w = speed
    vec4 params;    // x = time (seconds); y = per-draw phase; z = height cap (0 = none)
} ubo;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec3 v_worldpos;
layout(location = 3) out float v_cutoff;
layout(location = 4) out vec4 v_tangent;

// sway: vegetation displacement under the global wind (see grass.vert / the long note above).
// bend = whole-plant lean; shimmer = per-vertex flutter on alpha-tested foliage faces only.
vec3 sway(vec3 local, vec3 world, float root_z, float cutoff) {
    float h = max(world.z - root_z, 0.0);
    if (ubo.params.z > 0.0) h = min(h, ubo.params.z); // cap amplitude on tall foliage
    float bend = sin(ubo.params.x * ubo.wind.w + ubo.params.y) * ubo.wind.z * h;
    vec3 d = vec3(ubo.wind.xy * bend, 0.0);
    if (cutoff > 0.0) {
        float vph = (local.x + local.y + local.z) * 0.02; // per-vertex phase (Skyrim units)
        float f = sin(ubo.params.x * ubo.wind.w * 1.6 + ubo.params.y + vph) * ubo.wind.z * h * 0.6;
        d.xy += ubo.wind.xy * f;
        d.z += f * 0.4; // a little vertical wobble reads as fluttering
    }
    return d;
}

void main() {
    vec4 world = ubo.model * vec4(a_pos, 1.0);
    // model[3].z = world-space origin (root); mtl.x = alpha-test cutoff (foliage).
    world.xyz += sway(a_pos, world.xyz, ubo.model[3].z, ubo.mtl.x);
    gl_Position = ubo.vp * world;
    mat3 m3 = mat3(ubo.model);
    v_normal = m3 * a_normal;
    v_uv = a_uv;
    v_worldpos = world.xyz;
    v_cutoff = ubo.mtl.x;
    v_tangent = vec4(m3 * a_tangent.xyz, a_tangent.w);
}
