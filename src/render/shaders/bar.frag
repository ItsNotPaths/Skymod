#version 450
//
// Meter/progress-bar FILL fragment stage — the remade Skyrim `Components.Meter` fill. Rather than
// sample a bitmap, we synthesize a fake-cylindrical glossy bar: the fill is shaded as if it were a
// horizontal cylinder lit by a fixed key light (Blinn-Phong), giving the vanilla "glassy tube" sheen
// with a bright specular streak along the top. The fill grows from the left, right or centre, masked to `value`
// (0..1) so this ONE shader serves progress bars and H/M/S/level meters alike. Straight-alpha blend
// is set on the pipeline; the frame/track chrome are separate sibling quads drawn by the image path.

layout(location = 0) in vec2 v_uv; // 0..1 across the fill quad (x = along length, y = across height)
layout(location = 1) in vec4 v_col;

// std140: two vec4s (16-byte aligned each) so the Odin Bar_Params struct maps 1:1, no padding traps.
layout(set = 3, binding = 0) uniform Bar {
    vec4 fill; // rgba fill tint
    vec4 mask; // x = fill fraction 0..1 (the value); y = grows from (0 left, 1 centre, 2 right)
} B;

layout(location = 0) out vec4 out_color;

void main() {
    // t = distance from where the fill grows; past the value is empty (the track shows through).
    float t = B.mask.y < 0.5 ? v_uv.x : B.mask.y < 1.5 ? abs(v_uv.x * 2.0 - 1.0) : 1.0 - v_uv.x;
    if (t > B.mask.x) { discard; }

    // Fake a cylinder cross-section from the vertical coordinate: normal sweeps from facing-down at
    // the top edge, through straight-at-viewer in the middle, to facing-up at the bottom.
    float th = (v_uv.y - 0.5) * 1.9;                 // ~[-0.95, 0.95] rad
    vec3  n  = normalize(vec3(0.0, sin(th), cos(th)));

    const vec3 L = normalize(vec3(-0.2, -0.6, 0.75)); // key light (from upper-left, toward viewer)
    const vec3 V = vec3(0.0, 0.0, 1.0);               // view straight on
    vec3  H = normalize(L + V);

    float diff = clamp(dot(n, L) * 0.5 + 0.5, 0.0, 1.0);       // soft wrapped diffuse
    float spec = pow(max(dot(n, H), 0.0), 24.0);               // tight top-edge highlight

    vec3 rgb = B.fill.rgb * (0.55 + 0.45 * diff) + vec3(spec) * 0.6;

    // A faint brighter lip at the leading edge of the fill (reads as the meter "wet" tip).
    float edge = smoothstep(B.mask.x - 0.015, B.mask.x, t);
    rgb += vec3(edge) * 0.15;

    out_color = vec4(rgb, B.fill.a);
}
