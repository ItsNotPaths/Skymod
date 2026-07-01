#version 450
//
// Instanced grass (ROADMAP Section F2 vegetation). Each instance is one scattered
// grass cluster: a per-instance world position + hashed yaw / scale / wind-phase
// (vertex buffer slot 1, input rate INSTANCE). The base cluster mesh (slot 0) is the
// same position+normal+UV vertex as the general mesh path, so the FRAGMENT stage is
// shared with mesh.frag (same v_shade / v_uv / v_cutoff outputs, alpha-test cutout).
//
// WIND is the reusable, deliberately-basic part: a global direction/strength/speed +
// a per-instance phase drive a sine sway whose amplitude scales with blade height, so
// roots stay planted and tips move. It is isolated in sway() — a future physics sim
// (HDT-SMP-style) replaces/augments that single function (e.g. per-vertex offsets from
// a physics buffer) without touching the rest of the pipeline.

layout(location = 0) in vec3 a_pos;    // base cluster vertex (model space)
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec2 a_uv;
layout(location = 3) in vec4 a_tangent; // xyz tangent + w handedness
layout(location = 4) in vec3 i_pos;    // instance world position
layout(location = 5) in vec3 i_yps;    // instance yaw, scale, wind phase

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;          // view-projection (instance builds its own world matrix)
    mat4 model_local; // the grass NIF's internal shape transform
    vec4 mtl;         // x = alpha-test cutoff
    vec4 wind;        // xy = wind direction; z = strength; w = speed
    vec4 params;      // x = time (seconds)
} ubo;

// Per-pixel lighting moved to mesh.frag (shared): hand it the WORLD normal + WORLD position.
layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec3 v_worldpos;
layout(location = 3) out float v_cutoff;
layout(location = 4) out vec4 v_tangent;

// sway: horizontal blade-tip displacement. Amplitude ∝ height above the root so the
// base stays anchored. THE seam for a future physics sim.
vec3 sway(vec3 world, float height, float phase) {
    float a = sin(ubo.params.x * ubo.wind.w + phase) * ubo.wind.z * height;
    return vec3(ubo.wind.xy * a, 0.0);
}

void main() {
    float yaw = i_yps.x, scale = i_yps.y, phase = i_yps.z;

    // NIF-internal transform, then per-instance scale + yaw (about Z) + translate.
    vec3 lp = (ubo.model_local * vec4(a_pos, 1.0)).xyz * scale;
    vec3 ln = mat3(ubo.model_local) * a_normal;
    vec3 lt = mat3(ubo.model_local) * a_tangent.xyz;
    float c = cos(yaw), s = sin(yaw);
    vec3 rp = vec3(lp.x * c - lp.y * s, lp.x * s + lp.y * c, lp.z);
    vec3 rn = vec3(ln.x * c - ln.y * s, ln.x * s + ln.y * c, ln.z);
    vec3 rt = vec3(lt.x * c - lt.y * s, lt.x * s + lt.y * c, lt.z);

    vec3 world = i_pos + rp;
    world += sway(world, max(rp.z, 0.0), phase);

    gl_Position = ubo.vp * vec4(world, 1.0);
    v_normal = rn;
    v_uv = a_uv;
    v_worldpos = world;
    v_cutoff = ubo.mtl.x;
    v_tangent = vec4(rt, a_tangent.w);
}
