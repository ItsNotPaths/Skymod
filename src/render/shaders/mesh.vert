#version 450
//
// General mesh vertex stage. Position + UV in; the per-draw UBO (set 1, binding 0) carries the
// view-projection + model matrix and the alpha cutoff.

layout(location = 0) in vec3 a_pos;
layout(location = 2) in vec2 a_uv;

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;    // view-projection
    mat4 model; // world transform
    vec4 mtl;   // x = alpha cutoff (foliage cutouts); y = fade-in
} ubo;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out float v_cutoff;
layout(location = 2) out float v_fade;

void main() {
    gl_Position = ubo.vp * ubo.model * vec4(a_pos, 1.0);
    v_uv = a_uv;
    v_cutoff = ubo.mtl.x;
    v_fade = ubo.mtl.y;
}
