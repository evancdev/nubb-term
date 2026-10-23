const std = @import("std");

/// The font backend. Nubb is macOS-only, so CoreText handles font
/// discovery, rasterization, and shaping.
pub const Backend = enum {
    coretext,

    /// Returns the default backend for a build environment. This is
    /// meant to be called at comptime by the build.zig script. To get the
    /// backend look at build_options.
    pub fn default(target: std.Target) Backend {
        _ = target;
        return .coretext;
    }
};
