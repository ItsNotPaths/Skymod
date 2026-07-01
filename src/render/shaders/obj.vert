#version 450
//
// Instanced static objects (ROADMAP object-LOD tier 2). Distant statics are drawn as
// GPU instances of a shared (coarse-LOD) mesh: per-instance a full world matrix (vertex
// buffer slot 1, four vec4 columns, input rate INSTANCE). The fragment stage is shared
// with mesh.frag (same v_shade / v_uv / v_cutoff — alpha-test cutouts work for tree
// leaves). The coarse LOD level is chosen on the CPU via a truncated index draw.
//
// WIND (ROADMAP vegetation): the same procedural sway as mesh.vert / grass.vert. The
// global wind direction/strength/speed is shared; the per-instance PHASE is derived
// from the instance's world position so neighbouring trees move out of sync (but all in
// the SAME direction). strength 0 (non-vegetation batches) is a no-op.

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec2 a_uv;
layout(location = 3) in vec4 a_tangent; // xyz tangent + w handedness
layout(location = 4) in vec4 i_c0; // instance world matrix, column 0
layout(location = 5) in vec4 i_c1;
layout(location = 6) in vec4 i_c2;
layout(location = 7) in vec4 i_c3;

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;          // view-projection
    mat4 model_local; // the NIF shape's internal transform (shared by all instances)
    vec4 mtl;         // x = alpha-test cutoff
    vec4 wind;        // xy = global wind direction; z = strength; w = speed
    vec4 params;      // x = time (seconds); z = height cap (0 = none)
} ubo;

// Per-pixel lighting moved to mesh.frag (shared): hand it the WORLD normal + WORLD position.
layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec3 v_worldpos;
layout(location = 3) out float v_cutoff;
layout(location = 4) out vec4 v_tangent;

void main() {
    mat4 m = mat4(i_c0, i_c1, i_c2, i_c3) * ubo.model_local;
    vec4 world = m * vec4(a_pos, 1.0);
    // Per-instance phase from the instance origin (m[3]) so trees desync; one direction.
    float phase = i_c3.x * 0.013 + i_c3.y * 0.017;
    float h = max(world.z - m[3].z, 0.0);
    if (ubo.params.z > 0.0) h = min(h, ubo.params.z); // cap amplitude on tall foliage
    // Per-type amplitude (wind.z) + frequency (wind.w); whole-plant bend + (on alpha-tested
    // foliage faces) a per-vertex shimmer — mirrors mesh.vert so distant trees move like near ones.
    float bend = sin(ubo.params.x * ubo.wind.w + phase) * ubo.wind.z * h;
    world.xy += ubo.wind.xy * bend;
    if (ubo.mtl.x > 0.0) {
        float vph = (a_pos.x + a_pos.y + a_pos.z) * 0.02;
        float f = sin(ubo.params.x * ubo.wind.w * 1.6 + phase + vph) * ubo.wind.z * h * 0.6;
        world.xy += ubo.wind.xy * f;
        world.z += f * 0.4;
    }
    gl_Position = ubo.vp * world;
    mat3 m3 = mat3(m);
    v_normal = m3 * a_normal;
    v_uv = a_uv;
    v_worldpos = world.xyz;
    v_cutoff = ubo.mtl.x;
    v_tangent = vec4(m3 * a_tangent.xyz, a_tangent.w);
}
