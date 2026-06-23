#version 450
//
// Textured cube (ROADMAP Phase 0, step 4): straight texture sample. SDL3_gpu
// Vulkan binding model: fragment samplers live in descriptor set 2.

layout(location = 0) in vec2 v_uv;

layout(set = 2, binding = 0) uniform sampler2D u_tex;

layout(location = 0) out vec4 o_color;

void main() {
    o_color = texture(u_tex, v_uv);
}
