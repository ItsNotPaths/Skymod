#version 450
//
// Player-UI fragment stage (backend v2). Output = vertex colour × texel. The font atlas stores
// rgb = 1 and a = glyph coverage, and the rect path binds a 1×1 white texture, so a glyph paints
// the node colour modulated by coverage (anti-aliased text) and a rect paints the node colour flat.
// Straight-alpha blend (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) is set on the pipeline.

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_col;

layout(set = 2, binding = 0) uniform sampler2D u_tex;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = v_col * texture(u_tex, v_uv);
}
