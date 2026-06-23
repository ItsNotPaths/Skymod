#version 450
//
// Textured cube (ROADMAP Phase 0, step 4). Position + UV in; MVP from the vertex
// uniform block. SDL3_gpu Vulkan binding model: vertex uniform buffers live in
// descriptor set 1.

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;

layout(set = 1, binding = 0) uniform UBO {
    mat4 mvp;
} ubo;

layout(location = 0) out vec2 v_uv;

void main() {
    v_uv = a_uv;
    gl_Position = ubo.mvp * vec4(a_pos, 1.0);
}
