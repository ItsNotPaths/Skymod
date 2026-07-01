#version 450
//
// Stencil portal quad (ROADMAP open interiors). The doorway opening, a world-space quad,
// projected by the EXTERIOR camera. Position only — the quad's normal/uv (it reuses the
// Mesh_Vertex layout so render.upload_mesh builds it) are unused; the portal pipelines mask
// off color, so this shader only has to place the quad for the depth + stencil tests.

layout(location = 0) in vec3 a_pos;

layout(set = 1, binding = 0) uniform UBO {
    mat4 mvp; // exterior view-projection (quad verts are already world space)
} ubo;

void main() {
    gl_Position = ubo.mvp * vec4(a_pos, 1.0);
}
