#version 450
//
// CDLOD terrain fragment stage (terrain pivot, phase 4). A copy of mesh.frag's forward lighting
// (sun + hemispheric ambient + CSM shadow + fog) with ONE change: the diffuse comes from a ground
// texture ARRAY indexed per-cell, instead of a single bound diffuse. v_field_uv (0..1 over the
// worldspace) samples the index map (R8, nearest) → the cell's layer; v_uv (per-cell tiling)
// samples that layer of the array (mipped, so distance downscaling is automatic). Terrain has no
// authored normal/tangent, so normal mapping degenerates to the geometric normal (as in mesh.frag).
// Kept textually parallel to mesh.frag — lighting changes must touch both until shaders share code.

layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec2 v_uv;        // per-cell tiling UV (into the ground array layer)
layout(location = 2) in vec3 v_worldpos;
layout(location = 3) in float v_cutoff;
layout(location = 4) in vec4 v_tangent;
layout(location = 5) in vec2 v_field_uv;   // 0..1 over the worldspace (into the index map)
layout(location = 6) in vec2 v_inv_extent; // 1 / world extent (world→UV scale for the jitter)

layout(set = 2, binding = 0) uniform sampler2DArray u_ground; // per-cell ground diffuse layers
layout(set = 2, binding = 1) uniform sampler2D u_normal;      // flat-normal fallback (terrain has none)
layout(set = 2, binding = 2) uniform sampler2DArray u_shadow; // CSM depth, one layer per cascade
layout(set = 2, binding = 3) uniform sampler2D u_index;       // R8 per-cell layer index (nearest)

layout(set = 3, binding = 0) uniform Light {
    vec4 sun_dir;
    vec4 sun_color;
    vec4 ambient_sky;
    vec4 ambient_ground;
    vec4 fog_color;
    vec4 fog_params;
    vec4 cam_pos;
    vec4 material;
    mat4 csm_vp[3];
    vec4 csm_splits;
    vec4 shadow_params;
} L;

float sun_shadow(vec3 wp, float ndl) {
    if (L.shadow_params.w < 0.5 || ndl <= 0.0) return 1.0;
    float dist = length(wp - L.cam_pos.xyz);
    int c = 0;
    for (int i = 0; i < 3; i++) {
        if (dist > L.csm_splits[i]) c = i + 1;
    }
    if (c >= 3) return 1.0;
    vec4 lc = L.csm_vp[c] * vec4(wp, 1.0);
    vec3 p = lc.xyz / lc.w;
    vec2 uv = vec2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5));
    if (p.z > 1.0 || uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
    float bias = L.shadow_params.y;
    float step = L.shadow_params.z;
    float sum = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            float d = texture(u_shadow, vec3(uv + vec2(x, y) * step, float(c))).r;
            sum += (p.z - bias > d) ? 0.0 : 1.0;
        }
    }
    return sum / 9.0;
}

layout(set = 3, binding = 1) uniform Mat {
    vec4 spec;
    vec4 emissive;
    vec4 params;
} M;

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
    vec3 albedo = pow(max(tex.rgb, vec3(0.0)), vec3(L.sun_dir.w)); // albedo_lift

    vec3 N = normalize(v_normal);
    vec4 nm = texture(u_normal, v_uv);
    vec3 T = v_tangent.xyz - N * dot(N, v_tangent.xyz);
    float tlen = length(T);
    vec3 Np = N;
    if (tlen >= 1e-4) {
        T /= tlen;
        vec3 B = cross(N, T) * v_tangent.w;
        vec3 tn = nm.xyz * 2.0 - 1.0;
        tn.xy *= L.material.y;
        Np = normalize(mat3(T, B, N) * tn);
    }

    vec3 Ld = normalize(L.sun_dir.xyz);
    float ndl = max(dot(Np, Ld), 0.0);
    vec3 sun = L.sun_color.rgb * L.sun_color.w;

    float up = clamp(Np.z * 0.5 + 0.5, 0.0, 1.0);
    vec3 amb = mix(L.ambient_ground.rgb, L.ambient_sky.rgb, up) * L.ambient_ground.w;
    amb = max(amb, vec3(L.ambient_sky.w));

    float sh = sun_shadow(v_worldpos, ndl);
    float shade = 1.0 - L.shadow_params.x * (1.0 - sh);

    vec3 lit = albedo * (sun * ndl * shade + amb);

    // Emissive (terrain has none, but keep the shared form).
    lit += M.emissive.rgb * M.emissive.w * L.material.z;

    float dist = length(v_worldpos - L.cam_pos.xyz);
    float fog = clamp((dist - L.fog_params.x) / max(L.fog_params.y - L.fog_params.x, 1.0), 0.0, 1.0);
    fog *= L.fog_params.w;
    fog *= exp(-max(v_worldpos.z, 0.0) * L.fog_params.z);
    lit = mix(lit, L.fog_color.rgb, clamp(fog, 0.0, 1.0));

    out_color = vec4(lit, 1.0);
}
