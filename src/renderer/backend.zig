const std = @import("std");

/// Possible implementations, used for build options. Nubb is macOS-only,
/// so Metal is the only renderer.
pub const Backend = enum {
    metal,

    pub fn default(target: std.Target) Backend {
        _ = target;
        return .metal;
    }
};
