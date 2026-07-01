#version 450
//
// HDR post / tonemap (ROADMAP full-scene-lighting Phase B). The scene renders into an
// offscreen RGBA16F target (so lit values may exceed 1.0); this pass resolves it to the
// swapchain: exposure → tonemap operator → saturation / contrast / color-filter grade.
//
// TONEMAP OPERATORS (selected by the profile's `tonemap` enum, params.y):
//   0 Reinhard-with-white-point — the CE-faithful curve (Skyrim's hardcoded HDR is a
//     Reinhard variant); the natural "vanilla" choice.
//   1 ACES (Narkowicz approx) — filmic; rolls off + DESATURATES highlights → the "realistic,
//     brighter, less-saturated" look.
//   2 Uncharted2 filmic — alternative filmic curve, normalized by the white point.
//   3 None — passthrough (exposure + clamp only, no curve); the fullbright dev preset wants
//     the raw albedo on screen, so any compressive operator would just darken it.
// All output ~linear [0,1]; the swapchain encodes (matches the pre-HDR output convention).

layout(location = 0) in vec2 v_uv;

layout(set = 2, binding = 0) uniform sampler2D u_scene;

layout(set = 3, binding = 0) uniform Post {
    vec4 params; // x = exposure, y = tonemap mode, z = white point, w = contrast
    vec4 grade;  // xyz = color filter (tint), w = saturation
} P;

layout(location = 0) out vec4 out_color;

vec3 reinhard_white(vec3 c, float w) {
    return c * (1.0 + c / max(w * w, 1e-4)) / (1.0 + c);
}

vec3 aces(vec3 c) {
    const float a = 2.51, b = 0.03, cc = 2.43, d = 0.59, e = 0.14;
    return clamp((c * (a * c + b)) / (c * (cc * c + d) + e), 0.0, 1.0);
}

vec3 uncharted2_curve(vec3 x) {
    const float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}
vec3 filmic(vec3 c, float w) {
    return uncharted2_curve(c) / max(uncharted2_curve(vec3(max(w, 1e-3))), vec3(1e-4));
}

void main() {
    vec3 c = texture(u_scene, v_uv).rgb;
    c *= max(P.params.x, 0.0); // exposure

    int mode = int(P.params.y + 0.5);
    if (mode == 1) {
        c = aces(c);
    } else if (mode == 2) {
        c = filmic(c, P.params.z);
    } else if (mode == 3) {
        c = clamp(c, 0.0, 1.0); // passthrough (fullbright)
    } else {
        c = reinhard_white(c, P.params.z);
    }

    // Grade: saturation (lerp toward luminance), contrast (around 0.5), color-filter tint.
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    c = mix(vec3(l), c, P.grade.w);
    c = (c - 0.5) * P.params.w + 0.5;
    c *= P.grade.xyz;

    out_color = vec4(clamp(c, 0.0, 1.0), 1.0);
}
