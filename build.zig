const std = @import("std");
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

    const config = try buildpkg.Config.init(b, app_zon_version);
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

    // Nubb bench tools
    if (config.emit_bench) {
        const bench = try buildpkg.NubbBench.init(b, &deps);
        bench.install();
    }

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

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
                .resources = &resources,
            },
        );
        if (config.emit_macos_app) {
            macos_app.install();
        }
    }

    // Run step
    {
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
            test_step.dependOn(&test_exe_install.step);
        }
        _ = try deps.add(test_exe);

        addNubbH(b, test_exe.root_module, config.baselineTarget(b.graph.io), .debug);

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
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
