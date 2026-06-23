#version 450
//
// General mesh (ROADMAP Iteration 1, Milestone B4). Position + normal + UV in; MVP
// and model matrices + a light direction from the vertex uniform block (descriptor
// set 1, the SDL3_gpu Vulkan slot for vertex uniform buffers). Diffuse N·L shading
// is computed here and passed to the fragment stage as a scalar; the UV passes
// through so the fragment stage can sample the diffuse map (B4).

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec2 a_uv;

layout(set = 1, binding = 0) uniform UBO {
    mat4 mvp;
    mat4 model;
    vec4 light_dir; // xyz = direction toward the light (world space); w = alpha cutoff
} ubo;

layout(location = 0) out float v_shade;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out float v_cutoff;

void main() {
    gl_Position = ubo.mvp * vec4(a_pos, 1.0);
    vec3 n = normalize(mat3(ubo.model) * a_normal);
    float ndl = max(dot(n, normalize(ubo.light_dir.xyz)), 0.0);
    v_shade = 0.3 + 0.7 * ndl; // ambient + diffuse
    v_uv = a_uv;
    v_cutoff = ubo.light_dir.w;
}
