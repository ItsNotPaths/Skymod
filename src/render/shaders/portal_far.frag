#version 450
//
// Portal DEPTH-RESET fragment shader. Used by portal_reset_pipeline: where stencil == 1
// (the marked doorway region), force depth to FAR so the interior drawn next isn't occluded
// by the exterior geometry that was behind the door. Color is masked off; depth compare is
// ALWAYS + depth-write on, so this stamps far depth across exactly the opening. Under
// reversed-Z (perspective_rh_zo_rev) the far plane is 0.0, not 1.0.

layout(location = 0) out vec4 o_color;

void main() {
    gl_FragDepth = 0.0; // reversed-Z far plane
    o_color = vec4(0.0);
}
