// Scanlines: faint horizontal lines, like an old monitor, with no other
// distortion. It doesn't use time, so it only redraws when the terminal
// does.

const float STRENGTH = 0.24;  // How dark the lines get, 0 to 1.
const float PERIOD = 4.0;     // Distance between lines, in pixels.

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    float line = 0.5 + 0.5 * cos(fragCoord.y * 6.2831853 / PERIOD);

    // Lift the bright rows a little so the screen doesn't look dimmer.
    float shade = (1.0 - STRENGTH * line) * (1.0 + 0.5 * STRENGTH);
    fragColor = vec4(base.rgb * shade, base.a);
}
