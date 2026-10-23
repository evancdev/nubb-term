const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");
const translate_c = @import("translate_c");

/// App version from build.zig.zon.
const app_zon_version = @import("build.zig.zon").version;

/// Minimum required zig version.
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    buildpkg.requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.

    // If we have a VERSION file (present in source tarballs) then we
    // use that as the version source of truth. Otherwise we fall back
    // to what is in the build.zig.zon.
    const file_version: ?[]const u8 = if (b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        .limited(128),
    )) |content| std.mem.trim(
        u8,
        content,
        &std.ascii.whitespace,
    ) else |_| null;

    const config = try buildpkg.Config.init(
        b,
        file_version orelse app_zon_version,
    );
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    // Nubb dependencies used by many artifacts.
    const deps = try buildpkg.SharedDeps.init(b, &config);

    // The modules exported for Zig consumers of libnubb. If you're
    // writing a Zig program that uses libnubb, read this file.
    const mod = try buildpkg.NubbZig.init(
        b,
        &config,
        &deps,
    );

    // All our steps which we'll hook up later. The steps are shown
    // up here just so that they are more self-documenting.
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run tests");
    const test_lib_vt_step = b.step(
        "test-lib-vt",
        "Run nubb-vt module tests",
    );
    const test_lib_vt_build_step = b.step(
        "test-lib-vt-build",
        "Build nubb-vt module tests without running them (compile check)",
    );

    // Nubb resources like terminfo, shell integration, themes, etc.
    const resources = try buildpkg.NubbResources.init(b, &config, &deps);

    // Nubb executable, the actual runnable Nubb program.
    const exe = try buildpkg.NubbExe.init(b, &config, &deps);

    // Nubb docs
    const docs = try buildpkg.NubbDocs.init(b, &deps);
    if (config.emit_docs) {
        docs.install();
    } else if (config.target.result.os.tag.isDarwin()) {
        // If we aren't emitting docs we need to emit a placeholder so
        // our macOS xcodeproject builds since it expects the `share/man`
        // directory to exist to copy into the app bundle.
        docs.installDummy(b.getInstallStep());
    }

    // Nubb webdata
    const webdata = try buildpkg.NubbWebdata.init(b, &deps);
    if (config.emit_webdata) webdata.install();

    // Nubb bench tools
    if (config.emit_bench) {
        const bench = try buildpkg.NubbBench.init(b, &deps);
        bench.install();
    }

    // Nubb dist tarball
    const dist = try buildpkg.NubbDist.init(b, &config);
    {
        const step = b.step("dist", "Build the dist tarball");
        step.dependOn(dist.install_step);
        const check_step = b.step("distcheck", "Install and validate the dist tarball");
        check_step.dependOn(dist.check_step);
        check_step.dependOn(dist.install_step);
    }

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

    // Runtime "none" is libnubb, anything else is an executable.
    if (config.app_runtime != .none) {
        if (config.emit_exe) {
            exe.install();
            resources.install();
        }
    } else if (!config.is_dep) {
        // The macOS Nubb Library
        //
        // This is NOT libnubb (even though its named that for historical
        // reasons). It is just the glue between Nubb GUI on macOS and
        // the full Nubb GUI core.
        const lib_shared = try buildpkg.NubbLib.initShared(b, &deps);
        const lib_static = try buildpkg.NubbLib.initStatic(b, &deps);

        // We shouldn't have this guard but we don't currently
        // build on macOS this way ironically so we need to fix that.
        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.installHeader(); // Only need one header
            lib_shared.install("nubb-internal.so");
            lib_static.install("nubb-internal.a");
        }
    }

    // macOS only artifacts. These will error if they're initialized for
    // other targets.
    if (!config.is_dep and config.target.result.os.tag.isDarwin() and
        (config.emit_xcframework or config.emit_macos_app))
    {
        // Nubb xcframework
        const xcframework = try buildpkg.NubbXCFramework.init(
            b,
            &deps,
            config.xcframework_target,
        );
        if (config.emit_xcframework) {
            xcframework.install();

            // The xcframework build always installs resources because our
            // macOS xcode project contains references to them.
            resources.install();
        }

        // Nubb macOS app
        const macos_app = try buildpkg.NubbXcodebuild.init(
            b,
            &config,
            .{
                .xcframework = &xcframework,
                .docs = &docs,
                .resources = &resources,
            },
        );
        if (config.emit_macos_app) {
            macos_app.install();
        }
    }

    // Run step
    run: {
        if (config.app_runtime != .none) {
            const run_cmd = b.addRunArtifact(exe.exe);
            run_cmd.addPassthruArgs();

            // Set the proper resources dir so things like shell integration
            // work correctly. If we're running `zig build run` in Nubb,
            // this also ensures it overwrites the release one with our debug
            // build.
            // FIXME: This is not possible after Zig 0.17.
            // run_cmd.setEnvironmentVariable(
            //     "NUBB_RESOURCES_DIR",
            //     b.getInstallPath(.prefix, "share/nubb"),
            // );

            run_step.dependOn(&run_cmd.step);
            break :run;
        }

        assert(config.app_runtime == .none);

        // On macOS we can run the macOS app. For "run" we always force
        // a native-only build so that we can run as quickly as possible.
        if (!config.is_dep and
            config.target.result.os.tag.isDarwin() and
            (config.emit_xcframework or config.emit_macos_app))
        {
            const xcframework_native = try buildpkg.NubbXCFramework.init(
                b,
                &deps,
                .native,
            );
            const macos_app_native_only = try buildpkg.NubbXcodebuild.init(
                b,
                &config,
                .{
                    .xcframework = &xcframework_native,
                    .docs = &docs,
                    .resources = &resources,
                },
            );

            // Run uses the native macOS app
            run_step.dependOn(&macos_app_native_only.open.step);

            // If we have no test filters, install the tests too
            if (test_filters.len == 0) {
                macos_app_native_only.addTestStepDependencies(test_step);
            }
        }
    }

    // Zig module tests
    {
        const mod_vt_test = b.addTest(.{
            .root_module = mod.vt,
            .filters = test_filters,
        });
        const mod_vt_test_run = b.addRunArtifact(mod_vt_test);
        test_lib_vt_step.dependOn(&mod_vt_test_run.step);
        test_lib_vt_build_step.dependOn(&mod_vt_test.step);
    }

    // Tests (skip when built as a dependency, which only needs nubb-vt)
    if (!config.is_dep) {
        // Full unit tests
        const test_exe = b.addTest(.{
            .name = "nubb-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(b.graph.io),
                .optimize = .debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            // Crash on x86_64 without this
            .use_llvm = true,
        });
        if (config.emit_test_exe) {
            const test_exe_install = b.addInstallArtifact(test_exe, .{});
            config.addPatchElf(test_exe, &test_exe_install.step);
            test_step.dependOn(&test_exe_install.step);
        }
        _ = try deps.add(test_exe);

        addNubbH(b, test_exe.root_module, config.baselineTarget(b.graph.io), .debug);

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
        config.addPatchElf(test_exe, &test_run.step);
        test_step.dependOn(&test_run.step);

        // Normal tests always test our libnubb modules
        //test_step.dependOn(test_lib_vt_step);
    }
}

fn addNubbH(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    translate_c.addImportToModule(b, "nubb.h", module, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "nubb.h" },
        } } },
        .target = target,
        .optimize = optimize,
        .system_include_paths = &.{b.path("include")},
    }) catch unreachable;
}
