const NubbXCFramework = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const NubbLib = @import("NubbLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;

xcframework: *XCFrameworkStep,
target: Target,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !NubbXCFramework {
    // Universal macOS build
    const macos_universal = try NubbLib.initMacOSUniversal(b, deps);

    // Native macOS build
    const macos_native = try NubbLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));

    // Generate a headers directory with only nubb.h and the module
    // map, so Clang's module system sees exactly the umbrella header.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("include/nubb.h"), "nubb.h");
    _ = wf.addCopyFile(b.path("include/module.modulemap"), "module.modulemap");
    const headers = wf.getDirectory();

    // The xcframework wraps our nubb library so that we can link
    // it to the final app built with Swift.
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "NubbKit",
        .out_path = .{ .source_tree = "macos/NubbKit.xcframework" },
        .libraries = switch (target) {
            .universal => &.{
                .{
                    .library = macos_universal.output,
                    .headers = headers,
                    .dsym = macos_universal.dsym,
                },
            },

            .native => &.{.{
                .library = macos_native.output,
                .headers = headers,
                .dsym = macos_native.dsym,
            }},
        },
    });

    return .{
        .xcframework = xcframework,
        .target = target,
    };
}

pub fn install(self: *const NubbXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const NubbXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}
