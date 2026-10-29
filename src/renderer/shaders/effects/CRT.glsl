// CRT: a curved glass screen with scanlines, a soft vignette and a slight
// color fringe. It doesn't use time, so it only redraws when the terminal
// does.

const float CURVE = 0.035;     // How far the screen bows. 0 is flat.
const float SCANLINES = 0.16;  // How dark the scanlines get, 0 to 1.
const float FRINGE = 0.75;     // Red and blue offset, in pixels.
const float VIGNETTE = 0.22;   // How much the corners darken, 0 to 1.

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;

    // Bow each axis by the square of the other, so the middle of each
    // edge stays put and the corners curve away into the bezel.
    vec2 c = uv * 2.0 - 1.0;
    c *= vec2(1.0 + CURVE * c.y * c.y, 1.0 + CURVE * c.x * c.x);
    uv = c * 0.5 + 0.5;

    // Fade to the black bezel over about a pixel instead of a hard edge.
    vec2 inside = min(uv, 1.0 - uv) * iResolution.xy;
    float screen = clamp(min(inside.x, inside.y), 0.0, 1.0);
    if (screen <= 0.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec2 shift = vec2(FRINGE / iResolution.x, 0.0);
    vec4 base = texture(iChannel0, uv);
    vec3 col = vec3(
        texture(iChannel0, uv + shift).r,
        base.g,
        texture(iChannel0, uv - shift).b
    );

    // Scanlines every 3 pixels, following the curve.
    float line = 0.5 + 0.5 * cos(uv.y * iResolution.y * 2.0943951);
    col *= 1.0 - SCANLINES * line;

    float v = 16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y);
    col *= mix(1.0 - VIGNETTE, 1.0, pow(v, 0.3));

    fragColor = vec4(col * screen, mix(1.0, base.a, screen));
}
