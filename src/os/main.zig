//! The "os" package contains utilities for interfacing with the operating
//! system. These aren't restricted to syscalls or low-level operations, butos/main.zig
//! also OS-specific features and conventions.

const builtin = @import("builtin");

const desktop = @import("desktop.zig");
const file = @import("file.zig");
const homedir = @import("homedir.zig");
const locale = @import("locale.zig");
const mouse = @import("mouse.zig");
const openpkg = @import("open.zig");
const pipepkg = @import("pipe.zig");
const resourcesdir = @import("resourcesdir.zig");

// Namespaces
pub const edit = @import("edit.zig");
pub const hostname = @import("hostname.zig");
pub const mach = @import("mach.zig");
pub const path = @import("path.zig");
pub const passwd = @import("passwd.zig");
pub const xdg = @import("xdg.zig");
pub const macos = @import("macos.zig");
pub const shell = @import("shell.zig");
pub const stderr = @import("stderr.zig");
pub const uri = @import("uri.zig");

// Functions and types
pub const CFReleaseThread = @import("cf_release_thread.zig");
pub const TempDir = @import("TempDir.zig");
pub const launchedFromDesktop = desktop.launchedFromDesktop;
pub const rlimit = file.rlimit;
pub const fixMaxFiles = file.fixMaxFiles;
pub const restoreMaxFiles = file.restoreMaxFiles;
pub const randomTmpPath = file.randomTmpPath;
pub const home = homedir.home;
pub const expandHome = homedir.expandHome;
pub const ensureLocale = locale.ensureLocale;
pub const clickInterval = mouse.clickInterval;
pub const open = openpkg.open;
pub const OpenType = openpkg.Type;
pub const pipe = pipepkg.pipe;
pub const resourcesDir = resourcesdir.resourcesDir;
pub const ResourcesDir = resourcesdir.ResourcesDir;
pub const ShellEscapeWriter = shell.ShellEscapeWriter;
pub const getConfigEditCommand = edit.getConfigEditCommand;

test {
    _ = file;
    _ = stderr;
    _ = edit;
    _ = path;
    _ = uri;
    _ = shell;

    if (comptime builtin.target.os.tag.isDarwin()) {
        _ = mach;
        _ = macos;
    }
}
