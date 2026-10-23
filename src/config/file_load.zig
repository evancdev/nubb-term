const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.config);

/// The XDG config subdirectory. Nubb never reads `$XDG_CONFIG_HOME/ghostty`,
/// which belongs to Ghostty itself.
const xdg_subdir = "nubb";

/// The configuration file name.
const config_file = "config.nubb";

/// The extensionless configuration file name, still read for compatibility.
const legacy_config_file = "config";

/// The file name Nubb used before the rename. Only read from Nubb's own
/// Application Support directory, and only while `config.nubb` is missing.
const ghostty_config_file = "config.ghostty";

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try xdgPath(alloc, &environ_map, config_file);
}

/// Extensionless default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn legacyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try xdgPath(alloc, &environ_map, legacy_config_file);
}

fn xdgPath(
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
    file: []const u8,
) ![]const u8 {
    const subdir = try std.fs.path.join(alloc, &.{ xdg_subdir, file });
    defer alloc.free(subdir);
    return try internal_os.xdg.config(
        global.io(),
        alloc,
        environ_map,
        .{ .subdir = subdir },
    );
}

/// Preferred default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try preferredXdgPathIn(global.io(), alloc, &environ_map);
}

fn preferredXdgPathIn(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const u8 {
    const path = try xdgPath(alloc, environ_map, config_file);
    errdefer alloc.free(path);
    const legacy_path = try xdgPath(alloc, environ_map, legacy_config_file);
    return pickPath(io, alloc, &.{ path, legacy_path });
}

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, config_file);
}

/// Extensionless default path for the macOS Application Support
/// configuration file. Returned value must be freed by the caller.
pub fn legacyDefaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, legacy_config_file);
}

/// Pre-rename path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn ghosttyAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, ghostty_config_file);
}

/// Preferred default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn preferredAppSupportPath(alloc: Allocator) ![]const u8 {
    const dir = try internal_os.macos.appSupportDir(alloc, "");
    defer alloc.free(dir);
    return try preferredAppSupportPathIn(global.io(), alloc, dir);
}

/// Picks the config file in the Application Support directory `dir`:
/// `config.nubb`, then the pre-rename `config.ghostty`, then `config`.
/// If none exist, returns `config.nubb`.
fn preferredAppSupportPathIn(
    io: std.Io,
    alloc: Allocator,
    dir: []const u8,
) ![]const u8 {
    var candidates: [3][]const u8 = undefined;
    var n: usize = 0;
    errdefer for (candidates[0..n]) |p| alloc.free(p);
    for ([_][]const u8{ config_file, ghostty_config_file, legacy_config_file }) |name| {
        candidates[n] = try std.fs.path.join(alloc, &.{ dir, name });
        n += 1;
    }

    const path = pickPath(io, alloc, &candidates);
    if (std.mem.eql(u8, std.fs.path.basename(path), ghostty_config_file)) {
        log.info(
            "loading pre-rename config file, rename it to {s} path={s}",
            .{ config_file, path },
        );
    }
    return path;
}

/// Returns the first candidate that exists and is non-empty, or the first
/// candidate if none do. Takes ownership of every candidate and frees the
/// ones it does not return.
fn pickPath(
    io: std.Io,
    alloc: Allocator,
    candidates: []const []const u8,
) []const u8 {
    assert(candidates.len > 0);
    var chosen: usize = 0;
    for (candidates, 0..) |path, i| {
        if (open(io, path)) |f| {
            f.close(io);
            chosen = i;
            break;
        } else |_| {}
    }

    for (candidates, 0..) |path, i| {
        if (i != chosen) alloc.free(path);
    }
    return candidates[chosen];
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    switch (builtin.target.os.tag) {
        .macos => {
            // macOS prefers the Application Support directory
            // if it exists.
            const app_support_path = try preferredAppSupportPath(alloc);
            const app_support_file = open(global.io(), app_support_path) catch {
                // Try the XDG path if it exists
                const xdg_path = try preferredXdgPath(alloc);
                const xdg_file = open(global.io(), xdg_path) catch {
                    // If neither file exists, use app support
                    alloc.free(xdg_path);
                    return app_support_path;
                };
                xdg_file.close(global.io());
                alloc.free(app_support_path);
                return xdg_path;
            };
            app_support_file.close(global.io());
            return app_support_path;
        },

        // All other platforms use XDG only
        else => return try preferredXdgPath(alloc),
    }
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(io: std.Io, path: []const u8) OpenFileError!std.Io.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.Io.Dir.openFileAbsolute(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close(io);

    const stat = file.stat(io) catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}

fn testWrite(dir: std.Io.Dir, sub_path: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(std.testing.io, parent);
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = "a = b\n" });
}

test "app support: reads config.ghostty while config.nubb is missing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir);

    // Nothing exists: the new name is the one to create.
    {
        const path = try preferredAppSupportPathIn(io, alloc, dir);
        defer alloc.free(path);
        try testing.expectEqualStrings(config_file, std.fs.path.basename(path));
    }

    // Only the pre-rename file exists: it is read, and preferred over `config`.
    try testWrite(tmp.dir, legacy_config_file);
    try testWrite(tmp.dir, ghostty_config_file);
    {
        const path = try preferredAppSupportPathIn(io, alloc, dir);
        defer alloc.free(path);
        try testing.expectEqualStrings(ghostty_config_file, std.fs.path.basename(path));
    }

    // Once config.nubb exists, config.ghostty is ignored.
    try testWrite(tmp.dir, config_file);
    {
        const path = try preferredAppSupportPathIn(io, alloc, dir);
        defer alloc.free(path);
        try testing.expectEqualStrings(config_file, std.fs.path.basename(path));
    }
}

test "xdg: the ghostty config dir is never read" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();
    try environ_map.put("XDG_CONFIG_HOME", root);

    // Only Ghostty's own XDG config exists, under every name it uses.
    try testWrite(tmp.dir, "ghostty/config.ghostty");
    try testWrite(tmp.dir, "ghostty/config");
    try testWrite(tmp.dir, "ghostty/config.nubb");
    {
        const path = try preferredXdgPathIn(io, alloc, &environ_map);
        defer alloc.free(path);
        const expected = try std.fs.path.join(alloc, &.{ root, xdg_subdir, config_file });
        defer alloc.free(expected);
        try testing.expectEqualStrings(expected, path);
        try testing.expectError(error.FileNotFound, open(io, path));
    }

    // The nubb dir has no config.ghostty fallback either, only `config`.
    try testWrite(tmp.dir, "nubb/config.ghostty");
    try testWrite(tmp.dir, "nubb/config");
    {
        const path = try preferredXdgPathIn(io, alloc, &environ_map);
        defer alloc.free(path);
        const expected = try std.fs.path.join(alloc, &.{ root, xdg_subdir, legacy_config_file });
        defer alloc.free(expected);
        try testing.expectEqualStrings(expected, path);
    }

    try testWrite(tmp.dir, "nubb/config.nubb");
    {
        const path = try preferredXdgPathIn(io, alloc, &environ_map);
        defer alloc.free(path);
        const expected = try std.fs.path.join(alloc, &.{ root, xdg_subdir, config_file });
        defer alloc.free(expected);
        try testing.expectEqualStrings(expected, path);
    }
}
