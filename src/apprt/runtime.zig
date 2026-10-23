const std = @import("std");

/// Runtime is the runtime to use for Nubb. All runtimes do not provide
/// equivalent feature sets.
pub const Runtime = enum {
    /// Will not produce an executable at all when `zig build` is called.
    /// This is only useful if you're only interested in the lib only (macOS).
    none,

    pub fn default(target: std.Target) Runtime {
        // We do NONE so we don't create an exe and we create libnubb.
        // On macOS, Xcode is used to build the app that links to libnubb.
        _ = target;
        return .none;
    }
};

test {
    _ = Runtime;
}
