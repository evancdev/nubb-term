/// Build configuration. This is the configuration that is populated
/// during `zig build` to control the rest of the build process.
const Config = @This();

const std = @import("std");
const builtin = @import("builtin");

const ApprtRuntime = @import("../apprt/runtime.zig").Runtime;
const FontBackend = @import("../font/backend.zig").Backend;
const RendererBackend = @import("../renderer/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const XCFrameworkTarget = @import("xcframework.zig").Target;
const expandPath = @import("../os/path.zig").expand;

const GitVersion = @import("GitVersion.zig");

/// Standard build configuration options.
optimize: std.lang.Optimize,
target: std.Build.ResolvedTarget,
xcframework_target: XCFrameworkTarget = .universal,

/// Comptime interfaces
app_runtime: ApprtRuntime = .none,
renderer: RendererBackend = .metal,
font_backend: FontBackend = .coretext,

/// Feature flags
simd: bool = true,

/// Nubb exe properties
exe_entrypoint: ExeEntrypoint = .nubb,
version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },

/// Binary properties
pie: bool = false,
strip: bool = false,
patchelf: ?PatchElf = null,

/// Artifacts
emit_bench: bool = false,
emit_docs: bool = false,
emit_exe: bool = false,
emit_helpgen: bool = false,
emit_macos_app: bool = false,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
emit_themes: bool = false,
emit_xcframework: bool = false,
emit_webdata: bool = false,
emit_unicode_table_gen: bool = false,

/// True when Nubb is being built as a dependency of another project
/// rather than as the root project. Dependency builds (test/esctest,
/// test/fuzz-libnubb) only need the nubb-vt module, so they skip the
/// app, xcframework, and docs by default.
is_dep: bool = false,

/// Environmental properties
env: *const std.process.Environ.Map,

pub fn init(b: *std.Build, appVersion: []const u8) !Config {
    // Setup our standard Zig target and optimize options, i.e.
    // `-Doptimize` and `-Dtarget`.
    const optimize = b.standardOptimizeOption(.{});

    const is_dep = b.dep_prefix.len > 0;
    const target = target: {
        var result = b.standardTargetOptions(.{});

        // If we're building for macOS and we're on macOS, we need to
        // use a generic target to workaround compilation issues.
        if (result.result.os.tag == .macos and
            builtin.target.os.tag.isDarwin())
        {
            result = genericMacOSTarget(b, result.query.cpu_arch);
        }

        // If we have no minimum OS version, we set the default based on
        // our tag. Not all tags have a minimum so this may be null.
        if (result.query.os_version_min == null) {
            result.query.os_version_min = osVersionMin(result.result.os.tag);
        }

        break :target result;
    };

    // This is set to true when we're building a system package. For now
    // this is trivially detected using the "system_package_mode" bool
    // but we may want to make this more sophisticated in the future.
    const system_package = b.graph.system_package_mode;

    // Grab the environment from build state
    const env = &b.graph.environ_map;

    // We use env vars throughout the build so we grab them immediately here.
    var config: Config = .{
        .optimize = optimize,
        .target = target,
        .is_dep = is_dep,
        .env = env,
    };

    //---------------------------------------------------------------
    // Target-specific properties
    config.xcframework_target = b.option(
        XCFrameworkTarget,
        "xcframework-target",
        "The target for the xcframework.",
    ) orelse .universal;

    //---------------------------------------------------------------
    // Comptime Interfaces
    config.font_backend = b.option(
        FontBackend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse FontBackend.default(target.result);

    config.app_runtime = b.option(
        ApprtRuntime,
        "app-runtime",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse .none;

    config.renderer = b.option(
        RendererBackend,
        "renderer",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse RendererBackend.default(target.result);

    //---------------------------------------------------------------
    // Feature Flags

    config.simd = b.option(
        bool,
        "simd",
        "Build with SIMD-accelerated code paths. Results in significant performance improvements.",
    ) orelse true;

    //---------------------------------------------------------------
    // Nubb Exe Properties

    const version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );

    config.version = if (version_string) |v|
        // If an explicit version is given, we always use it.
        try std.SemanticVersion.parse(v)
    else version: {
        const app_version = try std.SemanticVersion.parse(appVersion);

        // Is nubb a dependency? If so, skip git detection.
        if (is_dep) break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
        };

        // If no explicit version is given, we try to detect it from git.
        const vsn = GitVersion.detect(b) catch |err| switch (err) {
            // If Git isn't available we just make an unknown dev version.
            error.GitNotFound,
            error.GitNotRepository,
            => break :version .{
                .major = app_version.major,
                .minor = app_version.minor,
                .patch = app_version.patch,
                .pre = "dev",
                .build = "0000000",
            },

            else => return err,
        };
        if (vsn.tag) |tag| {
            // Tip releases behave just like any other pre-release so we skip.
            if (!std.mem.eql(u8, tag, "tip")) {
                const expected = b.fmt("v{d}.{d}.{d}", .{
                    app_version.major,
                    app_version.minor,
                    app_version.patch,
                });

                if (!std.mem.eql(u8, tag, expected)) {
                    @panic("tagged releases must be in vX.Y.Z format matching build.zig");
                }

                break :version .{
                    .major = app_version.major,
                    .minor = app_version.minor,
                    .patch = app_version.patch,
                };
            }
        }

        break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
            .pre = vsn.branch,
            .build = vsn.short_hash,
        };
    };

    //---------------------------------------------------------------
    // Binary Properties

    // On NixOS, the built binary from `zig build` needs to patch the interp
    // and rpath into the built binary for it to be portable across the NixOS
    // system it was built for. We default this to true if we can detect we're
    // in a Nix shell.
    //
    // Note that this option is only available on Linux and if building
    // natively.
    //
    // NOTE: Zig does now have an option to pass in the dynamic linker
    // (-Ddynamic-linker), but it does seem to have some issues in 0.16.0 that
    // may be fixed in 0.17.0. We may want to revisit this afterwards; although
    // I'm not too sure if that helps to clean up rpath, this may just be the
    // better option. See https://codeberg.org/ziglang/zig/issues/31760.
    if (b.option(
        []const u8,
        "patch-interp",
        "Inject the supplied path as the dynamic linker in the built binary. " ++
            "Under Nix, this defaults to the dynamic linker found in PATH.",
    )) |interp| {
        PatchElf.setInterp(&config, interp);
    } else patch_interp: {
        if (!(target.result.os.tag == .linux) or !target.query.isNativeCpu()) break :patch_interp;
        if (env.get("IN_NIX_SHELL") == null) break :patch_interp;

        if (b.findProgram(.{ .names = &.{"ld.so"} })) |ld_so| {
            PatchElf.setInterp(
                &config,
                std.Io.Dir.realPathFileAbsoluteAlloc(b.graph.io, ld_so, b.allocator) catch break :patch_interp,
            );
        } else {}
    }

    if (b.option(
        []const u8,
        "patch-rpath",
        "Inject the supplied colon-delimited search path as the rpath in the built binary. " ++
            "This defaults to LD_LIBRARY_PATH if we're in a Nix shell environment.",
    )) |rpath| {
        PatchElf.setRpath(&config, rpath);
    } else patch_rpath: {
        if (!(target.result.os.tag == .linux) or !target.query.isNativeCpu()) break :patch_rpath;
        if (env.get("IN_NIX_SHELL") == null) break :patch_rpath;

        if (env.get("LD_LIBRARY_PATH")) |ld_library_path| {
            if (ld_library_path.len > 0) {
                PatchElf.setRpath(&config, ld_library_path);
            }
        }
    }

    config.pie = b.option(
        bool,
        "pie",
        "Build a Position Independent Executable. Default true for system packages.",
    ) orelse system_package;

    config.strip = b.option(
        bool,
        "strip",
        "Strip the final executable. Default true for fast and small releases",
    ) orelse switch (optimize) {
        .debug => false,
        .safe => false,
        .fast, .small => true,
    };

    //---------------------------------------------------------------
    // Artifacts to Emit

    config.emit_exe = b.option(
        bool,
        "emit-exe",
        "Build and install main executables with 'build'",
    ) orelse !is_dep;

    config.emit_test_exe = b.option(
        bool,
        "emit-test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    config.emit_unicode_table_gen = b.option(
        bool,
        "emit-unicode-table-gen",
        "Build and install executables that generate unicode tables with 'build'",
    ) orelse false;

    config.emit_bench = b.option(
        bool,
        "emit-bench",
        "Build and install the benchmark executables.",
    ) orelse false;

    config.emit_helpgen = b.option(
        bool,
        "emit-helpgen",
        "Build and install the helpgen executable.",
    ) orelse false;

    config.emit_docs = b.option(
        bool,
        "emit-docs",
        "Build and install auto-generated documentation (requires pandoc)",
    ) orelse emit_docs: {
        // If we are emitting any other artifacts then we default to false.
        if (config.emit_bench or
            config.emit_test_exe or
            config.emit_helpgen or
            config.is_dep) break :emit_docs false;

        // We always emit docs in system package mode.
        if (system_package) break :emit_docs true;

        // We only default to true if we can find pandoc.
        const path = expandPath(b.graph.io, b.allocator, &b.graph.environ_map, "pandoc") catch
            break :emit_docs false;
        defer if (path) |p| b.allocator.free(p);
        break :emit_docs path != null;
    };

    config.emit_terminfo = b.option(
        bool,
        "emit-terminfo",
        "Install Nubb terminfo source file",
    ) orelse switch (optimize) {
        .debug => true,
        .safe, .fast, .small => false,
    };

    config.emit_termcap = b.option(
        bool,
        "emit-termcap",
        "Install Nubb termcap file",
    ) orelse switch (optimize) {
        .debug => true,
        .safe, .fast, .small => false,
    };

    config.emit_themes = b.option(
        bool,
        "emit-themes",
        "Install bundled iTerm2-Color-Schemes Nubb themes",
    ) orelse true;

    config.emit_webdata = b.option(
        bool,
        "emit-webdata",
        "Build the website data for the website.",
    ) orelse false;

    config.emit_xcframework = b.option(
        bool,
        "emit-xcframework",
        "Build and install the xcframework for the macOS library.",
    ) orelse emit_xcfw: {
        if (!builtin.target.os.tag.isDarwin() or target.result.os.tag != .macos)
            break :emit_xcfw false;
        if (config.is_dep) break :emit_xcfw false;
        break :emit_xcfw config.app_runtime == .none and
            (!config.emit_bench and
                !config.emit_test_exe and
                !config.emit_helpgen);
    };

    config.emit_macos_app = b.option(
        bool,
        "emit-macos-app",
        "Build and install the macOS app bundle.",
    ) orelse !config.is_dep and config.emit_xcframework;

    //---------------------------------------------------------------
    // System Packages

    // These are all our dependencies that can be used with system
    // packages if they exist. We set them up here so that we can set
    // their defaults early. The first call configures the integration and
    // subsequent calls just return the configured value. This lets them
    // show up properly in `--help`.

    {
        // These dependencies we want to default false if we're on macOS.
        // On macOS we don't want to use system libraries because we
        // generally want a fat binary. This can be overridden with the
        // `-fsys` flag.
        for (&[_][]const u8{
            "freetype",
            "libpng",
            "zlib",
            "oniguruma",
        }) |dep| {
            _ = b.systemIntegrationOption(
                dep,
                .{
                    // If we're not on darwin we want to use whatever the
                    // default is via the system package mode
                    .default = if (target.result.os.tag.isDarwin()) false else null,
                },
            );
        }

        // These default to false because they're rarely available as
        // system packages so we usually want to statically link them.
        for (&[_][]const u8{
            "glslang",
            "spirv-cross",
            "simdutf",
        }) |dep| {
            _ = b.systemIntegrationOption(dep, .{ .default = false });
        }
    }

    return config;
}

const PatchElf = struct {
    interp: ?[]const u8 = null,
    rpath: ?[]const u8 = null,

    fn setInterp(config: *Config, interp: []const u8) void {
        if (config.patchelf) |*patchelf| {
            patchelf.interp = interp;
            return;
        }

        config.patchelf = .{ .interp = interp };
    }

    fn setRpath(config: *Config, rpath: []const u8) void {
        if (config.patchelf) |*patchelf| {
            patchelf.rpath = rpath;
            return;
        }

        config.patchelf = .{ .rpath = rpath };
    }
};

/// Add a patchelf step for the supplied `artifact`, depending on the supplied
/// `step`, if `patchelf` is present in the config.
pub fn addPatchElf(self: *const Config, artifact: *std.Build.Step.Compile, step: *std.Build.Step) void {
    const b = artifact.step.owner;
    std.debug.assert(b == step.owner);

    if (self.patchelf) |patchelf| {
        const run = std.Build.Step.Run.create(b, "patchelf");
        run.addArgs(&.{"patchelf"});
        if (patchelf.interp) |interp| run.addArgs(&.{ "--set-interpreter", interp });
        if (patchelf.rpath) |rpath| run.addArgs(&.{ "--set-rpath", rpath });
        run.addArtifactArg(artifact);
        step.dependOn(&run.step);
    }
}

/// Configure the build options with our values.
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    // We need to break these down individual because addOption doesn't
    // support all types.
    step.addOption(bool, "simd", self.simd);
    step.addOption(ApprtRuntime, "app_runtime", self.app_runtime);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(RendererBackend, "renderer", self.renderer);
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);

    // Our version. We also add the string version so we don't need
    // to do any allocations at runtime. This has to be long enough to
    // accommodate realistic large branch names for dev versions.
    var app_version_buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "app_version", self.version);
    step.addOption([:0]const u8, "app_version_string", try std.mem.printSentinel(
        &app_version_buf,
        "{f}",
        .{self.version},
        0,
    ));
    step.addOption(
        ReleaseChannel,
        "release_channel",
        channel: {
            const pre = self.version.pre orelse break :channel .stable;
            if (pre.len == 0) break :channel .stable;
            break :channel .tip;
        },
    );
}

/// Returns the build options for the terminal module. This assumes a
/// Nubb executable being built. Callers should modify this as needed.
pub fn terminalOptions(
    self: *const Config,
    artifact: TerminalBuildOptions.Artifact,
    optimize: std.lang.Optimize,
) TerminalBuildOptions {
    return .{
        .artifact = artifact,
        .simd = self.simd,
        .oniguruma = true,
        .version = self.version,
        .slow_runtime_safety = switch (optimize) {
            .debug => true,
            .safe,
            .small,
            .fast,
            => false,
        },
    };
}

/// Returns a baseline CPU target retaining all the other CPU configs.
pub fn baselineTarget(self: *const Config, io: std.Io) std.Build.ResolvedTarget {
    // Set our cpu model as baseline. There may need to be other modifications
    // we need to make such as resetting CPU features but for now this works.
    var q = self.target.query;
    q.cpu_model = .baseline;

    // Same logic as build.resolveTargetQuery but we don't need to
    // handle the native case.
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(io, q) catch
            @panic("unable to resolve baseline query"),
    };
}

/// Rehydrate our Config from the comptime options. Note that not all
/// options are available at comptime, so look closely at this implementation
/// to see what is and isn't available.
pub fn fromOptions() Config {
    const options = @import("build_options");
    return .{
        // Unused at runtime.
        .optimize = undefined,
        .target = undefined,
        .env = undefined,

        .version = options.app_version,
        .app_runtime = std.meta.stringToEnum(ApprtRuntime, @tagName(options.app_runtime)).?,
        .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?,
        .renderer = std.meta.stringToEnum(RendererBackend, @tagName(options.renderer)).?,
        .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
    };
}

/// Whether release artifacts should omit frame pointers.
///
/// Stripped release builds omit them in general, but we always keep frame
/// pointers on Apple platforms: the Apple arm64 ABI expects x29 to
/// be a valid frame pointer and Apple's profiling and crash reporting
/// tools rely on it for backtraces.
pub fn omitFramePointer(self: *const Config) bool {
    if (self.target.result.os.tag.isDarwin()) return false;
    return self.strip;
}

/// Returns the minimum OS version for the given OS tag. This shouldn't
/// be used generally, it should only be used for Darwin-based OS currently.
pub fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        // We support back to the earliest officially supported version
        // of macOS by Apple. EOL versions are not supported.
        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },

        // This should never happen currently. If we add a new target then
        // we should add a new case here.
        else => null,
    };
}

// Returns a ResolvedTarget for a mac with a `target.result.cpu.model.name` of `generic`.
// `b.standardTargetOptions()` returns a more specific cpu like `apple_a15`.
//
// This is used to workaround compilation issues on macOS.
// (see for example https://github.com/mitchellh/ghostty/issues/1640).
pub fn genericMacOSTarget(
    b: *std.Build,
    arch: ?std.Target.Cpu.Arch,
) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse builtin.target.cpu.arch,
        .os_tag = .macos,
        .os_version_min = osVersionMin(.macos),
    });
}

/// The possible entrypoints for the exe artifact. This has no effect on
/// other artifact types (i.e. lib).
///
/// The whole existence of this enum is to workaround the fact that Zig
/// doesn't allow the main function to be in a file in a subdirctory
/// from the "root" of the module, and I don't want to pollute our root
/// directory with a bunch of individual zig files for each entrypoint.
///
/// Therefore, main.zig uses this to switch between the different entrypoints.
pub const ExeEntrypoint = enum {
    nubb,
    helpgen,
    mdgen_nubb_1,
    mdgen_nubb_5,
    webgen_config,
    webgen_actions,
    webgen_commands,
};

/// The release channel for the build.
pub const ReleaseChannel = enum {
    /// Unstable builds on every commit.
    tip,

    /// Stable tagged releases.
    stable,
};
