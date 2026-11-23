const builtin = @import("builtin");
const HwyTargets = @import("targets.zig").Targets;

const x86 = @import("detect/x86.zig");
const aarch64_darwin = @import("detect/aarch64_darwin.zig");

/// Detect Highway targets at runtime using minimal, direct CPU feature
/// probing.
///
/// Previous versions called std.zig.system.resolveTargetQuery which
/// drags in the full Zig target/CPU model tables for every architecture,
/// bloating the binary by ~300 KB and causing code-layout regressions in
/// unrelated hot paths (icache / branch-predictor pressure).
///
/// This version uses only inline assembly (CPUID on x86) and
/// sysctlbyname on Apple Silicon, so it adds no data tables and no
/// std.Target dependency.
pub export fn ghostty_hwy_detect_targets() callconv(.c) i64 {
    return switch (builtin.target.cpu.arch) {
        .x86_64 => x86.detect(),
        .aarch64 => detectAarch64(),
        else => 0,
    };
}

fn detectAarch64() i64 {
    var t: HwyTargets = .{};

    // All AArch64 implementations have NEON.
    t.neon_without_aes = true;

    return aarch64_darwin.detect(&t);
}
