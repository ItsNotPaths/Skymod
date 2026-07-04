#version 450
//
// Meter/progress-bar FILL vertex stage. Identical to ui.vert: the `ui` package emits the bar's fill
// quad in SCREEN-PIXEL space (top-left origin, Y down), and this maps it to clip space against the
// swapchain size. The uv (0..1 across the quad) is handed to bar.frag so the sheen + value mask are
// computed in the fill's local space, independent of where the bar sits on screen.

layout(location = 0) in vec2 a_pos; // screen pixels
layout(location = 1) in vec2 a_uv;  // 0..1 across the fill quad
layout(location = 2) in vec4 a_col; // normalized rgba (unused by the fill; the UBO carries the tint)

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
