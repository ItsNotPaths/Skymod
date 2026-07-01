#version 450
//
// Player-UI vertex stage (backend v2). The `ui` package emits 2D quads in SCREEN-PIXEL space
// (top-left origin, Y down); this maps them to clip space against the swapchain size. One pipeline
// draws every UI primitive — solid rects (sampling a 1×1 white texture), font glyphs (sampling the
// font atlas), and art images — as vertex_color × texel, so the only per-batch state is the bound
// texture. Colour arrives as normalized UBYTE4 (rgba).

layout(location = 0) in vec2 a_pos; // screen pixels
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_col; // normalized rgba

layout(set = 1, binding = 0) uniform UBO {
    vec2 screen; // drawable size in pixels
    vec2 _pad;
} ubo;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_col;

void main() {
    vec2 p = a_pos / ubo.screen;                 // 0..1
    gl_Position = vec4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0); // Y flip (screen down → clip up)
    v_uv = a_uv;
    v_col = a_col;
}
