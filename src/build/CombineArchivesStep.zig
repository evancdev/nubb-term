//! Combines multiple static archives into a single fat archive.
const std = @import("std");
const LibtoolStep = @import("LibtoolStep.zig");

/// Combine multiple static archives into a single fat archive.
///
/// `name` identifies the library (e.g. "nubb-internal", "nubb-vt").
/// Output uses a `-fat` suffix to distinguish the combined archive from
/// the single-library archive in the build cache.
pub fn create(
    b: *std.Build,
    name: []const u8,
    sources: []const std.Build.LazyPath,
) struct { step: *std.Build.Step, output: std.Build.LazyPath } {
    const libtool = LibtoolStep.create(b, .{
        .name = name,
        .out_name = b.fmt("lib{s}-fat.a", .{name}),
        .sources = @constCast(sources),
    });
    return .{ .step = libtool.step, .output = libtool.output };
}
