const NubbLib = @This();

const std = @import("std");
const CombineArchivesStep = @import("CombineArchivesStep.zig");
const Config = @import("Config.zig");
const LibsystemOverrideStep = @import("LibsystemOverrideStep.zig");
const SharedDeps = @import("SharedDeps.zig");
const LipoStep = @import("LipoStep.zig");

/// The step that generates the file.
step: *std.Build.Step,

/// The final static library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,

pub fn initStatic(
    b: *std.Build,
    deps: *const SharedDeps,
) !NubbLib {
    const lib = b.addLibrary(.{
        .name = "nubb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.omitFramePointer(),
            .unwind_tables = if (deps.config.strip) .none else .sync,
            .link_libc = true,
        }),

        // Fails on self-hosted x86_64 on macOS
        .use_llvm = true,
    });

    // These must be bundled since we're compiling into a static lib.
    // Otherwise, you get undefined symbol errors.
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    // Add our dependencies. Get the list of all static deps so we can
    // build a combined archive.
    var lib_list = try deps.add(lib);
    try lib_list.append(b.allocator, lib.getEmittedBin());

    // Combine all archives into a single fat static library so
    // consumers only need to link one file.
    const combined = CombineArchivesStep.create(b, deps.config.target, "nubb-internal", lib_list.items);
    combined.step.dependOn(&lib.step);

    // On Darwin, prefer libSystem's libc/libm over the bundled
    // compiler-rt for consumers of this archive. See
    // libsystem_override.sh for details. This is a no-op elsewhere.
    const override = LibsystemOverrideStep.create(
        b,
        deps.config.target,
        combined.output,
        "libnubb-internal.a",
    );

    return .{
        .step = override.step orelse combined.step,
        .output = override.output,

        // Static libraries cannot have dSYMs because they aren't linked.
        .dsym = null,
    };
}

pub fn initMacOSUniversal(
    b: *std.Build,
    original_deps: *const SharedDeps,
) !NubbLib {
    const aarch64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .aarch64),
    ));
    const x86_64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .x86_64),
    ));

    const universal = LipoStep.create(b, .{
        .name = "nubb",
        .out_name = "nubb-internal.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });

    return .{
        .step = universal.step,
        .output = universal.output,

        // You can't run dsymutil on a universal binary, you have to
        // do it on the individual binaries.
        .dsym = null,
    };
}
