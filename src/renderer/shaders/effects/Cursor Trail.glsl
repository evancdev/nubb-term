// Cursor Trail: when the cursor jumps, a streak in the cursor's color
// follows it from where it was and shrinks into it. Typing doesn't leave a
// trail. This uses time, so Nubb redraws every frame while the terminal is
// focused.

const float DURATION = 0.16;  // Seconds until the trail is gone.
const float MIN_JUMP = 1.5;   // Moves shorter than this many cursor heights get no trail.

// Distance from p to the segment a-b, and how far along it (0 at a, 1 at b)
// the closest point is.
vec2 segment(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-4), 0.0, 1.0);
    return vec2(length(p - a - ab * t), t);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    // A cursor is (left, +Y edge, width, height), so it spans y - height to y.
    vec4 cur = iCurrentCursor;
    vec4 prev = iPreviousCursor;
    float progress = (iTime - iTimeCursorChange) / DURATION;
    if (progress >= 1.0 || prev.z <= 0.0 || cur.z <= 0.0) return;

    // Bar and underline cursors are thin on one side, so size the trail by
    // the long side.
    float size = max(cur.z, cur.w);
    vec2 head = cur.xy + vec2(0.5, -0.5) * cur.zw;
    vec2 tail = prev.xy + vec2(0.5, -0.5) * prev.zw;
    if (distance(head, tail) < MIN_JUMP * size) return;

    // The tail catches up to the head as the trail fades.
    float ease = 1.0 - (1.0 - progress) * (1.0 - progress);
    tail = mix(tail, head, ease);

    // Thin at the tail, as wide as the cursor at the head.
    vec2 hit = segment(fragCoord, tail, head);
    float radius = 0.25 * size * mix(0.25, 1.0, hit.y);
    float cover = clamp(radius - hit.x + 0.5, 0.0, 1.0);
    float alpha = cover * (1.0 - progress) * 0.85;

    fragColor = vec4(mix(base.rgb, iCurrentCursorColor.rgb, alpha), base.a);
}
