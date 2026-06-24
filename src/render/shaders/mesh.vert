#version 450
//
// General mesh (ROADMAP Iteration 1, Milestone B4). Position + normal + UV in; the
// view-projection + model matrices + a light direction from the vertex uniform block
// (descriptor set 1, the SDL3_gpu Vulkan slot for vertex uniform buffers). Diffuse N·L
// shading is computed here and passed to the fragment stage as a scalar; the UV passes
// through so the fragment stage can sample the diffuse map (B4).
//
// WIND (ROADMAP vegetation): the same procedural sway as grass.vert — a single GLOBAL
// wind direction/strength/speed (NOT per-instance directions) plus a per-draw phase
// drive a sine displacement whose amplitude scales with height above the model origin,
// so trunks/roots stay planted and canopies/tips move. strength 0 (every non-vegetation
// draw) leaves geometry exactly where vp·model places it. Isolated in sway() — the seam
// a future physics sim replaces.

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec2 a_uv;

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;        // view-projection
    mat4 model;     // world transform (also transforms normals)
    vec4 light_dir; // xyz = direction toward the light (world space); w = alpha cutoff
    vec4 wind;      // xy = global wind direction; z = strength; w = speed
    vec4 params;    // x = time (seconds); y = per-draw phase; z = height cap (0 = none)
} ubo;

layout(location = 0) out float v_shade;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out float v_cutoff;

// sway: vegetation displacement under the global wind. Amplitude (wind.z) AND frequency
// (wind.w) are set PER VEGETATION TYPE by the caller — heavy plants (trees) get a small,
// slow sway; light foliage gets a larger, faster one (CPU compensates for short plants'
// small height). Both terms scale with height above the model origin so roots/trunk-base
// stay planted:
//   bend    — whole-plant lean (trunk + canopy together).
//   shimmer — only the alpha-tested foliage FACES (cutoff > 0 = leaf/branch cards): a
//             per-vertex phase makes individual cards move out of sync (slightly faster),
//             so leaves read as the main motion without a violent whole-tree whip.
// THE seam for a future physics sim. One global wind DIRECTION throughout — only
// phase/amplitude/frequency vary.
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
    // model[3].z = world-space origin (root); light_dir.w = alpha-test cutoff (foliage).
    world.xyz += sway(a_pos, world.xyz, ubo.model[3].z, ubo.light_dir.w);
    gl_Position = ubo.vp * world;
    vec3 n = normalize(mat3(ubo.model) * a_normal);
    float ndl = max(dot(n, normalize(ubo.light_dir.xyz)), 0.0);
    v_shade = 0.3 + 0.7 * ndl; // ambient + diffuse
    v_uv = a_uv;
    v_cutoff = ubo.light_dir.w;
}
