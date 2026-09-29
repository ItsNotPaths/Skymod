#version 450
//
// Instanced static objects (ROADMAP object-LOD tier 2). Distant statics are drawn as
// GPU instances of a shared (coarse-LOD) mesh: per-instance a full world matrix (vertex
// buffer slot 1, four vec4 columns, input rate INSTANCE). The fragment stage is shared
// with mesh.frag (same v_uv / v_cutoff — alpha-test cutouts work for tree
// leaves). The coarse LOD level is chosen on the CPU via a truncated index draw.

layout(location = 0) in vec3 a_pos;
layout(location = 2) in vec2 a_uv;
layout(location = 4) in vec4 i_c0; // instance world matrix, column 0
layout(location = 5) in vec4 i_c1;
layout(location = 6) in vec4 i_c2;
layout(location = 7) in vec4 i_c3;

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;          // view-projection
    mat4 model_local; // the NIF shape's internal transform (shared by all instances)
    vec4 mtl;         // x = alpha-test cutoff; y = fade-in
} ubo;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out float v_cutoff;
layout(location = 2) out float v_fade;

void main() {
    mat4 m = mat4(i_c0, i_c1, i_c2, i_c3) * ubo.model_local;
    gl_Position = ubo.vp * m * vec4(a_pos, 1.0);
    v_uv = a_uv;
    v_cutoff = ubo.mtl.x;
    v_fade = ubo.mtl.y;
}
