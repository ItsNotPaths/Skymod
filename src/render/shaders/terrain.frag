#version 450
//
// CDLOD terrain fragment stage: fullbright, like mesh.frag, but the diffuse comes from a ground
// texture ARRAY indexed per-cell. v_field_uv (0..1 over the worldspace) samples the index map
// (R8, nearest) → the cell's layer; v_uv (per-cell tiling) samples that layer of the array.

layout(location = 0) in vec2 v_uv;         // per-cell tiling UV (into the ground array layer)
layout(location = 1) in vec3 v_worldpos;
layout(location = 2) in vec2 v_field_uv;   // 0..1 over the worldspace (into the index map)
layout(location = 3) in vec2 v_inv_extent; // 1 / world extent (world→UV scale for the jitter)
layout(location = 4) in float v_fade;

layout(set = 2, binding = 0) uniform sampler2DArray u_ground; // per-cell ground diffuse layers
layout(set = 2, binding = 1) uniform sampler2D u_index;       // R8 per-cell layer index (nearest)

layout(location = 0) out vec4 out_color;

// Smooth value noise (hash + bilinear), for organic boundary jitter + the blend factor.
float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + vec2(1, 0)), c = hash21(i + vec2(0, 1)), d = hash21(i + vec2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float layer_at(vec2 uv) {
    return floor(texture(u_index, clamp(uv, 0.0, 0.99999)).r * 255.0 + 0.5);
}

// Boundary blend tuned in WORLD UNITS (Skyrim: 4096/cell, ~64u/yard). HIGH frequency — tens of
// units, not thousands — so adjacent pixels differ and the index-texel grid dissolves into organic
// dithered transitions (a per-cell-frequency noise just shifts the hard edge; it doesn't mix).
const float TERR_WARP_PERIOD  = 130.0; // organic boundary-wiggle wavelength
const float TERR_BLEND_PERIOD = 64.0;  // finer dither across the blended band
const float TERR_JITTER       = 700.0; // how far the lookup reaches across a boundary (~1.4 index texels)

void main() {
    // Outside the worldspace bbox: the quadtree root overshoots past the NE edges; draw no terrain
    // there (the height clamp keeps that geometry flat, this drops it so there's no shelf).
    if (v_field_uv.x < 0.0 || v_field_uv.x >= 1.0 || v_field_uv.y < 0.0 || v_field_uv.y >= 1.0) discard;
    // temporary bandaid so streaming pop-in doesnt look like shit: dither in over v_fade (0..1).
    if (fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) >= v_fade) discard;

    // Soften painted-region boundaries: warp two index taps apart by high-frequency noise and blend
    // their ground layers. Inside a region both taps hit the same layer (no-op, full detail kept);
    // within ~JITTER of a boundary they differ and the dithered blend dissolves the hard edge.
    vec2 wp = v_worldpos.xy;
    vec2 warp = (vec2(vnoise(wp / TERR_WARP_PERIOD + 11.3), vnoise(wp / TERR_WARP_PERIOD + 57.7)) - 0.5)
                * TERR_JITTER * v_inv_extent;
    float la = layer_at(v_field_uv + warp);
    float lb = layer_at(v_field_uv - warp);
    // Hole cells are filled (height interpolated, texture borrowed from neighbours) so they render
    // as continuous terrain — no discard. (Only the bbox-overshoot discard above remains.)
    float t = vnoise(wp / TERR_BLEND_PERIOD + 3.1);
    vec4 tex = mix(texture(u_ground, vec3(v_uv, la)), texture(u_ground, vec3(v_uv, lb)), t);
    out_color = vec4(pow(tex.rgb, vec3(1.0 / 2.2)), 1.0); // sRGB-sampled texel back to display space
}
