//! GhosttyZig generates the `ghostty-vt` Zig module: the terminal core
//! as a plain Zig module. Nubb's test harnesses (test/fuzz-libghostty,
//! test/esctest) import it, and `zig build test-lib-vt` tests it.
const GhosttyZig = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;

vt: *std.Build.Module,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
) !GhosttyZig {
    // Terminal module build options
    var vt_options = cfg.terminalOptions(.lib, cfg.optimize);
    vt_options.artifact = .lib;
    // We presently don't allow Oniguruma in our Zig module at all.
    // We should expose this as a build option in the future so we can
    // conditionally do this.
    vt_options.oniguruma = false;

    return .{ .vt = try initVt(b, cfg, deps, vt_options) };
}

fn initVt(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    vt_options: TerminalBuildOptions,
) !*std.Build.Module {
    // General build options
    const general_options = b.addOptions();
    try cfg.addOptions(general_options);

    const vt = b.addModule("ghostty-vt", .{
        .root_source_file = b.path("src/lib_vt.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,

        // SIMD requires libc. Vendored C++ dependencies are built with
        // no-libcxx mode (HWY_NO_LIBCXX / SIMDUTF_NO_LIBCXX) so we
        // don't need libcpp. System-provided simdutf headers still
        // use C++ stdlib headers, so we need libcpp in that case.
        .link_libc = if (cfg.simd) true else null,
        .link_libcpp = if (cfg.simd and
            b.systemIntegrationOption("simdutf", .{}) and
            cfg.target.result.abi != .msvc) true else null,
    });
    vt.addOptions("build_options", general_options);
    vt_options.add(b, vt);

    // We always need unicode tables
    deps.unicode_tables.addModuleImport(vt);

    // We need uucode for grapheme break support
    vt.addImport("uucode", deps.uucode_mod);

    // We need wuffs for Kitty graphics pixel operations (format
    // conversion and alpha blending). Unlike pure Zig dependencies
    // its C code is compiled whenever the module is in the build
    // graph regardless of analysis, so only wire it in when Kitty
    // graphics is actually enabled.
    if (vt_options.kittyGraphics(cfg.target.result)) {
        if (b.lazyDependency("wuffs", .{
            .target = cfg.target,
            .optimize = cfg.optimize,
        })) |dep| {
            vt.addImport("wuffs", dep.module("wuffs"));
        }
    }

    // If SIMD is enabled, add all our SIMD dependencies.
    if (cfg.simd) {
        try SharedDeps.addSimd(b, vt, null);
    }

    return vt;
}
