#version 450
//
// General mesh fragment stage (ROADMAP full-scene-lighting Phases A–C). Per-PIXEL forward
// lighting in Skyrim's SPECULAR-GLOSSINESS model: directional sun + hemispheric ambient (with a
// floor) + tangent-space NORMAL MAPPING + Blinn-Phong sun specular + emissive + distance fog.
//
// Inputs: diffuse (set 2 binding 0) + normal map (binding 1, linear; flat-normal fallback when a
// shape has none). Per-frame lighting (set 3 binding 0) carries sun/ambient/fog + the GLOBAL
// material remap (spec_scale / normal_strength / emissive_scale — the runtime reinterpretation of
// CE-tuned values). Per-draw material (binding 1) carries the shape's authored spec color/strength,
// glossiness, emissive. Skyrim packs the specular MASK in the normal map's alpha.

layout(location = 0) in vec3 v_normal;   // world normal (interpolated)
layout(location = 1) in vec2 v_uv;
layout(location = 2) in vec3 v_worldpos;
layout(location = 3) in float v_cutoff;
layout(location = 4) in vec4 v_tangent;   // world tangent xyz + bitangent handedness w

layout(set = 2, binding = 0) uniform sampler2D u_diffuse;
layout(set = 2, binding = 1) uniform sampler2D u_normal;
layout(set = 2, binding = 2) uniform sampler2DArray u_shadow; // CSM depth, one layer per cascade

layout(set = 3, binding = 0) uniform Light {
    vec4 sun_dir;        // xyz toward sun; w = albedo_lift
    vec4 sun_color;      // rgb; w = sun intensity
    vec4 ambient_sky;    // rgb; w = ambient floor
    vec4 ambient_ground; // rgb; w = ambient intensity
    vec4 fog_color;      // rgb
    vec4 fog_params;     // x start, y end, z height falloff, w density
    vec4 cam_pos;        // xyz camera world pos
    vec4 material;       // x = spec_scale, y = normal_strength, z = emissive_scale, w = foliage_spec
    mat4 csm_vp[3];      // cascade light view-projections
    vec4 csm_splits;     // x,y,z = far radial distance per cascade
    vec4 shadow_params;  // x = strength, y = depth bias, z = PCF texel step, w = cascade count (0 = off)
} L;

// sun_shadow returns 1.0 (lit) … 0.0 (fully shadowed) for the world point, from the cascade
// covering its distance. 3x3 PCF for soft edges. Returns 1.0 when shadows are off, the surface
// faces away, or the point is beyond the last cascade / outside the map.
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
    // Flip V: SDL3_gpu's rendered image is y-flipped vs the sample UV (same as the post pass),
    // so undo it here — otherwise the shadow samples a mirrored texel and swims as the cascade
    // (which follows the camera) moves.
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
    vec4 spec;     // rgb = specular color; w = specular strength
    vec4 emissive; // rgb = emissive color; w = emissive multiple
    vec4 params;   // x = glossiness
} M;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 tex = texture(u_diffuse, v_uv);
    if (tex.a < v_cutoff) discard; // alpha-test foliage cutouts
    vec3 albedo = pow(max(tex.rgb, vec3(0.0)), vec3(L.sun_dir.w)); // albedo_lift (dark-authored fix)

    // Tangent-space normal mapping. Gram-Schmidt re-orthonormalize T against N, build B from the
    // authored handedness. GUARD a degenerate/zero tangent (e.g. terrain has no authored tangent):
    // normalize(0) is NaN and NaN·0 would poison the normal → black. Fall back to the geometric
    // normal there (correct, since those surfaces use the flat-normal fallback anyway).
    vec3 N = normalize(v_normal);
    vec4 nm = texture(u_normal, v_uv);
    vec3 T = v_tangent.xyz - N * dot(N, v_tangent.xyz);
    float tlen = length(T);
    vec3 Np = N;
    if (tlen >= 1e-4) {
        T /= tlen;
        vec3 B = cross(N, T) * v_tangent.w;
        vec3 tn = nm.xyz * 2.0 - 1.0;
        tn.xy *= L.material.y; // normal_strength
        Np = normalize(mat3(T, B, N) * tn);
    }

    vec3 Ld = normalize(L.sun_dir.xyz);
    float ndl = max(dot(Np, Ld), 0.0);
    vec3 sun = L.sun_color.rgb * L.sun_color.w;

    // Hemispheric ambient (ground→sky by up-facing factor) clamped up to the floor.
    float up = clamp(Np.z * 0.5 + 0.5, 0.0, 1.0);
    vec3 amb = mix(L.ambient_ground.rgb, L.ambient_sky.rgb, up) * L.ambient_ground.w;
    amb = max(amb, vec3(L.ambient_sky.w));

    // Sun shadow (CSM): 1 = lit, 0 = shadowed; `strength` scales how dark the shadow goes.
    float sh = sun_shadow(v_worldpos, ndl);
    float shade = 1.0 - L.shadow_params.x * (1.0 - sh);

    vec3 lit = albedo * (sun * ndl * shade + amb);

    // Specular (Blinn-Phong, sun only) — also shadowed. Strength = authored × spec_scale, masked
    // by the normal map's alpha (Skyrim's spec mask), tinted by the specular color. Alpha-tested
    // cutouts (v_cutoff > 0 = leaves/grass/plants) scale by foliage_spec (Skyrim over-authors spec).
    float spec_strength = M.spec.w * L.material.x;
    if (v_cutoff > 0.0) spec_strength *= L.material.w;
    if (spec_strength > 0.0 && ndl > 0.0) {
        vec3 V = normalize(L.cam_pos.xyz - v_worldpos);
        vec3 H = normalize(Ld + V);
        float s = pow(max(dot(Np, H), 0.0), max(M.params.x, 1.0));
        lit += sun * s * spec_strength * nm.a * M.spec.rgb * shade;
    }

    // Emissive (color × multiple × global emissive_scale).
    lit += M.emissive.rgb * M.emissive.w * L.material.z;

    // Distance fog (+ optional height attenuation).
    float dist = length(v_worldpos - L.cam_pos.xyz);
    float fog = clamp((dist - L.fog_params.x) / max(L.fog_params.y - L.fog_params.x, 1.0), 0.0, 1.0);
    fog *= L.fog_params.w;
    fog *= exp(-max(v_worldpos.z, 0.0) * L.fog_params.z);
    lit = mix(lit, L.fog_color.rgb, clamp(fog, 0.0, 1.0));

    out_color = vec4(lit, 1.0);
}
