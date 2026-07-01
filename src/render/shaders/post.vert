#version 450
//
// Fullscreen-triangle vertex stage for the HDR post pass (ROADMAP full-scene-lighting Phase B).
// No vertex buffer — three vertices generated from gl_VertexIndex cover the whole screen; the
// fragment stage (post.frag) samples the offscreen HDR scene target and tonemaps it. UV (0,0)
// maps to clip (-1,-1) so the sample is an identity copy of the scene image.

layout(location = 0) out vec2 v_uv;

void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    // Flip V: sampling the offscreen HDR target inverts the row order relative to the old
    // direct-to-swapchain path, so undo it here to keep the image upright.
    v_uv = vec2(p.x, 1.0 - p.y);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
