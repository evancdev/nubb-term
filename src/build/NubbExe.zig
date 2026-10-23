const Exe = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The primary Nubb executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Exe {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "nubb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.omitFramePointer(),
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    // Set PIE if requested
    if (cfg.pie) exe.pie = true;

    // Add the shared dependencies. When building only lib-vt we skip
    // heavy deps so cross-compilation doesn't pull in GTK, etc.
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    // Add patchelf step if that option is specified.
    cfg.addPatchElf(exe, &install_step.step);

    return .{
        .exe = exe,
        .install_step = install_step,
    };
}

/// Add the nubb exe to the install target.
pub fn install(self: *const Exe) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
