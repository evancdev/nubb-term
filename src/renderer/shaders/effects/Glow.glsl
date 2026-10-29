// Glow: a soft halo around text that is brighter than the background,
// like phosphor bloom. Dark text on a light theme gets no halo. It doesn't
// use time, so it only redraws when the terminal does.

const float RADIUS = 2.5;    // Spacing of the sample rings, in pixels.
const float STRENGTH = 1.2;  // How bright the halo gets.

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 px = 1.0 / iResolution.xy;
    vec2 uv = fragCoord * px;
    vec4 base = texture(iChannel0, uv);
    float bg = luma(iBackgroundColor);

    // Three rings of eight samples, each ring turned a little so the
    // samples don't line up into spokes. Closer rings count for more.
    vec3 glow = vec3(0.0);
    float total = 0.0;
    for (int ring = 1; ring <= 3; ring++) {
        float r = RADIUS * float(ring);
        float w = 1.0 / float(ring);
        for (int i = 0; i < 8; i++) {
            float a = (float(i) + 0.33 * float(ring)) * 0.7853982;
            vec3 s = texture(iChannel0, uv + vec2(cos(a), sin(a)) * r * px).rgb;
            glow += s * max(luma(s) - bg, 0.0) * w;
            total += w;
        }
    }

    fragColor = vec4(base.rgb + glow / total * STRENGTH, base.a);
}
