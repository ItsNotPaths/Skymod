#version 450
//
// General mesh (ROADMAP Iteration 1, Milestone B4): sample the diffuse map and
// modulate it by the vertex-stage N·L shade. SDL3_gpu Vulkan binding model: fragment
// samplers live in descriptor set 2. Untextured shapes bind a 1x1 white fallback so
// this same shader shows plain shading.

layout(location = 0) in float v_shade;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in float v_cutoff;

layout(set = 2, binding = 0) uniform sampler2D u_diffuse;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 d = texture(u_diffuse, v_uv);
    if (d.a < v_cutoff) discard; // alpha-test foliage cutouts (v_cutoff 0 = opaque)
    out_color = vec4(d.rgb * v_shade, 1.0);
}
