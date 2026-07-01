#version 450
//
// Stopgap water fragment stage: fully procedural, no normal-map asset and no reflection
// pass. The surface normal is the analytic gradient of a small sum of directional sine
// waves over world XY (cheap "modern" ripples without geometry). From that normal:
//   - fresnel blends a deep-water color into a sky/horizon tint at grazing angles,
//   - a sharp Blinn-Phong highlight gives the sun glint,
//   - the same fresnel raises opacity at grazing angles (water reads solid at the horizon,
//     see-through looking straight down).
// Lighting inputs (sun dir, camera) come from the shared-light UBO seam — when full scene
// lighting lands, this shader reads richer values from the same block.

layout(set = 3, binding = 0) uniform UBO {
    mat4 vp;
    vec4 cam;     // xyz = camera world pos
    vec4 sun;     // xyz = direction toward the sun
    vec4 deep;    // rgb deep-water color, a = base opacity
    vec4 shallow; // rgb horizon/sky tint
    vec4 params;  // x = time
} u;

layout(location = 0) in vec3 v_world;

layout(location = 0) out vec4 out_color;

// One directional wave's contribution to the surface-slope gradient (d height / d xy).
// dir = travel direction, wl = wavelength (world units), amp = height amplitude, spd =
// angular speed. height = amp*sin(dot(dir,p)*k + t*spd) → grad = amp*k*cos(...)*dir.
vec2 wave_grad(vec2 p, float t, vec2 dir, float wl, float amp, float spd) {
    dir = normalize(dir);
    float k = 6.2831853 / wl;
    float ph = dot(dir, p) * k + t * spd;
    return dir * (amp * k * cos(ph));
}

void main() {
    vec2 p = v_world.xy;
    float t = u.params.x;

    // Domain warp: shove the sample point with a couple of big slow swells before the fine
    // ripples sample it, so the periodic sines below don't tile into an obvious grid (the
    // cheap fix for "repetitious" water — no extra textures).
    vec2 warp = vec2(
        sin(p.y * 0.0011 + t * 0.50) + 0.6 * sin(p.x * 0.0017 - t * 0.37),
        sin(p.x * 0.0013 - t * 0.45) + 0.6 * sin(p.y * 0.0019 + t * 0.41));
    vec2 pw = p + warp * 120.0;

    // Several octaves of cross-travelling ripples at INCOMMENSURATE (prime-ish) wavelengths
    // and directions spread around the compass, so no single period reads as a pattern.
    vec2 g = vec2(0.0);
    g += wave_grad(pw, t, vec2( 1.00,  0.18), 311.0, 3.6, 0.83);
    g += wave_grad(pw, t, vec2(-0.42,  1.00), 197.0, 2.4, 1.07);
    g += wave_grad(pw, t, vec2( 0.77, -0.63), 127.0, 1.6, 1.31);
    g += wave_grad(pw, t, vec2(-0.88, -0.30),  83.0, 1.0, 1.69);
    g += wave_grad(pw, t, vec2( 0.21,  0.98),  53.0, 0.6, 2.11);
    g += wave_grad(pw, t, vec2( 0.96, -0.12),  37.0, 0.4, 2.53);
    g += wave_grad(pw, t, vec2(-0.34,  0.94),  23.0, 0.25, 3.07);
    vec3 N = normalize(vec3(-g, 1.0));

    vec3 V = normalize(u.cam.xyz - v_world);
    vec3 L = normalize(u.sun.xyz);

    // Fresnel (Schlick, water F0 ~ 0.02): low looking down, ~1 at grazing.
    float fres = mix(0.02, 1.0, pow(1.0 - max(dot(V, N), 0.0), 5.0));

    vec3 col = mix(u.deep.rgb, u.shallow.rgb, fres);

    // Sun glint (Blinn-Phong, tight exponent).
    vec3 H = normalize(L + V);
    col += vec3(1.0) * pow(max(dot(N, H), 0.0), 200.0) * 0.8;

    // Subtle directional shading so the ripples read as relief.
    col *= 0.7 + 0.3 * max(dot(N, L), 0.0);

    out_color = vec4(col, mix(u.deep.a, 1.0, fres));
}
