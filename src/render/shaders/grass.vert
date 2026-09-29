#version 450
//
// Instanced grass (ROADMAP Section F2 vegetation). Each instance is one scattered
// grass cluster: a per-instance world position + hashed yaw / scale (vertex buffer
// slot 1, input rate INSTANCE). The base cluster mesh (slot 0) is the same vertex as
// the general mesh path, so the FRAGMENT stage is shared with mesh.frag (same v_uv /
// v_cutoff outputs, alpha-test cutout).

layout(location = 0) in vec3 a_pos;    // base cluster vertex (model space)
layout(location = 2) in vec2 a_uv;
layout(location = 4) in vec3 i_pos;    // instance world position
layout(location = 5) in vec2 i_ys;     // instance yaw, scale

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;          // view-projection (instance builds its own world matrix)
    mat4 model_local; // the grass NIF's internal shape transform
    vec4 mtl;         // x = alpha-test cutoff; y = fade-in
} ubo;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out float v_cutoff;
layout(location = 2) out float v_fade;

void main() {
    float yaw = i_ys.x, scale = i_ys.y;

    // NIF-internal transform, then per-instance scale + yaw (about Z) + translate.
    vec3 lp = (ubo.model_local * vec4(a_pos, 1.0)).xyz * scale;
    float c = cos(yaw), s = sin(yaw);
    vec3 rp = vec3(lp.x * c - lp.y * s, lp.x * s + lp.y * c, lp.z);

    gl_Position = ubo.vp * vec4(i_pos + rp, 1.0);
    v_uv = a_uv;
    v_cutoff = ubo.mtl.x;
    v_fade = ubo.mtl.y;
}
