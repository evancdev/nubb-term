const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");

const c = @import("posix_c");

/// Returns true if the program was launched from a desktop environment.
///
/// On macOS, this returns true if the program was launched from Finder.
///
/// For other platforms and app runtimes, this returns false.
pub fn launchedFromDesktop() bool {
    return switch (builtin.target.os.tag) {
        // macOS apps launched from finder or `open` always have the init
        // process as their parent.
        .macos => macos: {
            // This special case is so that if we launch the app via the
            // app bundle (i.e. via open) then we still treat it as if it
            // was launched from the desktop.
            if (build_config.artifact == .lib) lib: {
                const env = "NUBB_MAC_LAUNCH_SOURCE";
                const source = global.environ().getPosix(env) orelse break :lib;

                // Source can be "app", "cli", or "zig_run". We assume
                // its the desktop only if its "app". We may want to do
                // "zig_run" but at the moment there's no reason.
                if (std.mem.eql(u8, source, "app")) break :macos true;
            }

            break :macos c.getppid() == 1;
        },

        // iPhone/iPad is always launched from the "desktop"
        .ios => true,

        else => @compileError("unsupported platform"),
    };
}
