#version 450
//
// General mesh fragment stage: fullbright. The diffuse texel as authored, alpha-tested.
// (hole day-night :tags (render unclaimed) :sev gap) the renderer is fullbright: no sun, ambient, shadows, fog or day/night curve.

layout(location = 0) in vec2 v_uv;
layout(location = 1) in float v_cutoff;
layout(location = 2) in float v_fade;

layout(set = 2, binding = 0) uniform sampler2D u_diffuse;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 tex = texture(u_diffuse, v_uv);
    if (tex.a < v_cutoff) discard; // alpha-test foliage cutouts
    // temporary bandaid so streaming pop-in doesnt look like shit: dither in over v_fade (0..1).
    if (fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) >= v_fade) discard;
    out_color = vec4(pow(tex.rgb, vec3(1.0 / 2.2)), 1.0); // sRGB-sampled texel back to display space
}
