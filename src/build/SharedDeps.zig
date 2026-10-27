const SharedDeps = @This();

const std = @import("std");
const builtin = @import("builtin");

const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const MetallibStep = @import("MetallibStep.zig");
const UnicodeTables = @import("UnicodeTables.zig");
const translate_c = @import("translate_c");

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
metallib: ?*MetallibStep,
unicode_tables: UnicodeTables,
uucode_tables: std.Build.LazyPath,

/// Singleton uucode module, instantiated once in `init` and reused
/// everywhere so that nubb and vaxis share the same compiled tables in
/// each final binary instead of each linking its own copy.
///
/// Sharing one instance is also a hard requirement (not just an
/// optimization) for Zig 0.16's strict module model. `SharedDeps.add` runs
/// many times across different (target, optimize) tuples (macos-aarch64,
/// macos-x86_64, ios-aarch64, Debug + ReleaseFast, etc.), and on each
/// call we have to wire uucode into both the step's root module and into
/// vaxis_mod (because vaxis's `Parser.zig` does `@import("uucode")` and
/// we pass `external_uucode = true` to vaxis's build.zig so vaxis doesn't
/// instantiate its own uucode dep). If those two import bindings ever
/// resolve to *different* `*Module` pointers within a single Compile
/// step's analysis, Zig fails with:
///
///     vaxis/src/Parser.zig: file exists in modules 'uucode' and 'uucode0'
///
/// because all those uucode module instances share the same physical
/// `uucode/src/root.zig` file on disk, and Zig requires every file to belong
/// to exactly one module within a Compile graph.
///
/// The natural way to keep them the same would be to call
/// `b.lazyDependency("uucode", .{ .tables_path, .build_config_path })`
/// from each call site and let Zig's dependency cache deduplicate
/// identical args. That fails because of a bug in Zig's
/// `userLazyPathsAreTheSame` (Build.zig) where the `.src_path` and
/// `.generated` equality checks are inverted: `if (std.mem.eql(...))
/// return false` instead of `if (!std.mem.eql(...)) return false`. The
/// dep cache key therefore always misses whenever any arg is a
/// `b.path(...)` LazyPath, so each call returns a fresh `*Dependency`
/// with a fresh `*Module`. Hoisting the dep into one eager
/// `b.dependency` call here sidesteps the cache entirely.
///
/// This conflict is independent of whether vaxis itself is acquired as a
/// singleton or per-target dep.
uucode_mod: *std.Build.Module,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !SharedDeps {
    const uucode_tables = blk: {
        const uucode = b.dependency("uucode", .{
            .build_config_path = b.path("src/build/uucode_config.zig"),
        });

        break :blk uucode.namedLazyPath("tables.zig");
    };

    // Instantiate the singleton uucode module that both nubb and vaxis
    // import. See the doc comment on `uucode_mod`.
    const uucode_mod = b.dependency("uucode", .{
        .tables_path = uucode_tables,
        .build_config_path = b.path("src/build/uucode_config.zig"),
    }).module("uucode");

    // Re-export the uucode module so that Zig programs that embed libgtostty-vt
    // can use it. This is necessary to use libraries like libvaxis in
    // the embedding program that need uucode as well (libvaxis provides
    // -Dexternal_uucode for this).
    try b.modules.put(b.allocator, b.dupe("uucode"), uucode_mod);

    var result: SharedDeps = .{
        .config = cfg,
        .help_strings = try .init(b, cfg),
        .unicode_tables = try .init(b, uucode_tables),
        .uucode_tables = uucode_tables,
        .uucode_mod = uucode_mod,

        // Setup by retarget
        .options = undefined,
        .metallib = undefined,
    };
    try result.initTarget(b, cfg.target);
    if (cfg.emit_unicode_table_gen) result.unicode_tables.install(b);
    return result;
}

/// Retarget our dependencies for another build target. Modifies in-place.
pub fn retarget(
    self: *const SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !SharedDeps {
    var result = self.*;
    try result.initTarget(b, target);
    return result;
}

/// Change the exe entrypoint.
pub fn changeEntrypoint(
    self: *const SharedDeps,
    b: *std.Build,
    entrypoint: Config.ExeEntrypoint,
) !SharedDeps {
    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.exe_entrypoint = entrypoint;

    var result = self.*;
    result.config = config;
    result.options = b.addOptions();
    try config.addOptions(result.options);

    return result;
}

fn initTarget(
    self: *SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !void {
    // Update our metallib
    self.metallib = .create(b, .{
        .name = "Nubb",
        .target = target,
        .sources = &.{b.path("src/renderer/shaders/shaders.metal")},
    });

    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.target = target;
    self.config = config;

    // Setup our shared build options
    self.options = b.addOptions();
    try self.config.addOptions(self.options);
}

pub fn add(
    self: *const SharedDeps,
    step: *std.Build.Step.Compile,
) !LazyPathList {
    const b = step.step.owner;

    // We could use our config.target/optimize fields here but its more
    // correct to always match our step.
    const target = step.root_module.resolved_target.?;
    const optimize = step.root_module.optimize.?;

    // We maintain a list of our static libraries and return it so that
    // we can build a single fat static library for the final app.
    var static_libs: LazyPathList = .empty;
    errdefer static_libs.deinit(b.allocator);

    // WARNING: This is a hack!
    // If we're cross-compiling to Darwin then we don't add any deps.
    // We don't support cross-compiling to Darwin but due to the way
    // lazy dependencies work with Zig, we call this function. So we just
    // bail. The build will fail but the build would've failed anyways.
    if (!builtin.target.os.tag.isDarwin() and
        self.config.target.result.os.tag.isDarwin())
    {
        return static_libs;
    }

    // Every exe gets build options populated
    step.root_module.addOptions("build_options", self.options);

    // Every exe needs the terminal options
    self.config.terminalOptions(.nubb, optimize).add(b, step.root_module);

    // Every exe needs the uucode module
    step.root_module.addImport("uucode", self.uucode_mod);

    // C imports for locale constants and functions
    try translate_c.addImportToModule(b, "locale-c", step.root_module, .{
        .source = .{ .file = b.path("src/os/locale.c") },
        .target = target,
        .optimize = optimize,
    });

    // C imports needed to manage/create PTYs
    switch (target.result.os.tag) {
        .macos,
        => {
            try translate_c.addImportToModule(b, "pty-c", step.root_module, .{
                .source = .{ .file = b.path("src/pty.c") },
                .target = target,
                .optimize = optimize,
            });
        },
        else => {},
    }

    // POSIX C imports that are used throughout Nubb on a general basis.
    // (note: errno is C stdlib but we just include it here because that's
    // where it's generally included otherwise)
    try translate_c.addImportToModule(b, "posix_c", step.root_module, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "errno.h" },
            .{ .path = "pwd.h" },
            .{ .path = "signal.h" },
            .{ .path = "sys/types.h" },
            .{ .path = "unistd.h" },
        } } },
        .target = target,
        .optimize = optimize,
    });

    // Oniguruma
    if (b.lazyDependency("oniguruma", .{
        .target = target,
        .optimize = optimize,
    })) |oniguruma_dep| {
        step.root_module.addImport(
            "oniguruma",
            oniguruma_dep.module("oniguruma"),
        );
        if (b.systemIntegrationOption("oniguruma", .{})) {
            step.root_module.linkSystemLibrary("oniguruma", dynamic_link_opts);
        } else {
            step.root_module.linkLibrary(oniguruma_dep.artifact("oniguruma"));
            try static_libs.append(
                b.allocator,
                oniguruma_dep.artifact("oniguruma").getEmittedBin(),
            );
        }
    }

    // Glslang
    if (b.lazyDependency("glslang", .{
        .target = target,
        .optimize = optimize,
    })) |glslang_dep| {
        step.root_module.addImport("glslang", glslang_dep.module("glslang"));
        if (b.systemIntegrationOption("glslang", .{})) {
            step.root_module.linkSystemLibrary("glslang", dynamic_link_opts);
            step.root_module.linkSystemLibrary(
                "glslang-default-resource-limits",
                dynamic_link_opts,
            );
        } else {
            step.root_module.linkLibrary(glslang_dep.artifact("glslang"));
            try static_libs.append(
                b.allocator,
                glslang_dep.artifact("glslang").getEmittedBin(),
            );
        }
    }

    // Spirv-cross
    if (b.lazyDependency("spirv_cross", .{
        .target = target,
        .optimize = optimize,
    })) |spirv_cross_dep| {
        step.root_module.addImport(
            "spirv_cross",
            spirv_cross_dep.module("spirv_cross"),
        );
        if (b.systemIntegrationOption("spirv-cross", .{})) {
            step.root_module.linkSystemLibrary("spirv-cross-c-shared", dynamic_link_opts);
        } else {
            step.root_module.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
            try static_libs.append(
                b.allocator,
                spirv_cross_dep.artifact("spirv_cross").getEmittedBin(),
            );
        }
    }

    // Simd
    if (self.config.simd) try addSimd(
        b,
        step.root_module,
        &static_libs,
    );

    // C files
    step.root_module.link_libc = true;

    // libcpp is required for various dependencies. On MSVC, we must
    // not use linkLibCpp because Zig unconditionally passes -nostdinc++
    // and then adds its bundled libc++/libc++abi include paths, which
    // conflict with MSVC's own C++ runtime headers. The MSVC SDK
    // include directories (already added via linkLibC above) contain
    // both C and C++ headers, so linkLibCpp is not needed.
    if (step.rootModuleTarget().abi != .msvc) {
        step.root_module.link_libcpp = true;
    }

    // We always require the system SDK so that our system headers are available.
    // This makes things like `os/log.h` available for cross-compiling.
    if (step.rootModuleTarget().os.tag.isDarwin()) {
        try @import("apple_sdk").addPaths(b, step);

        const metallib = self.metallib.?;
        metallib.output.addStepDependencies(&step.step);
        step.root_module.addAnonymousImport("nubb_metallib", .{
            .root_source_file = metallib.output,
        });
    }

    // Other dependencies, mostly pure Zig
    if (b.lazyDependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .external_uucode = true,
    })) |dep| {
        const vaxis = dep.module("vaxis");
        step.root_module.addImport("vaxis", vaxis);
        vaxis.addImport("uucode", self.uucode_mod);
    }
    if (b.lazyDependency("wuffs", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("wuffs", dep.module("wuffs"));
    }
    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("xev", dep.module("xev"));
    }
    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("z2d", dep.module("z2d"));
    }
    if (b.lazyDependency("zf", .{
        .target = target,
        .optimize = optimize,
        .with_tui = false,
    })) |dep| {
        step.root_module.addImport("zf", dep.module("zf"));
    }

    // Mac Stuff
    if (step.rootModuleTarget().os.tag.isDarwin()) {
        if (b.lazyDependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
        })) |objc_dep| {
            step.root_module.addImport(
                "objc",
                objc_dep.module("objc"),
            );
        }

        if (b.lazyDependency("macos", .{
            .target = target,
            .optimize = optimize,
        })) |macos_dep| {
            step.root_module.addImport(
                "macos",
                macos_dep.module("macos"),
            );
            step.root_module.linkLibrary(
                macos_dep.artifact("macos"),
            );
            try static_libs.append(
                b.allocator,
                macos_dep.artifact("macos").getEmittedBin(),
            );
        }
    }

    // Fonts
    {
        // JetBrains Mono
        if (b.lazyDependency("jetbrains_mono", .{})) |jb_mono| {
            step.root_module.addAnonymousImport(
                "jetbrains_mono_regular",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Regular.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_bold",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Bold.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_italic",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Italic.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_bold_italic",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-BoldItalic.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_variable",
                .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono[wght].ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_variable_italic",
                .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono-Italic[wght].ttf") },
            );
        }

        // Symbols-only nerd font
        if (b.lazyDependency("nerd_fonts_symbols_only", .{})) |nf_symbols| {
            step.root_module.addAnonymousImport(
                "nerd_fonts_symbols_only",
                .{ .root_source_file = nf_symbols.path("SymbolsNerdFont-Regular.ttf") },
            );
        }
    }

    self.help_strings.addImport(step);
    self.unicode_tables.addImport(step);

    return static_libs;
}

/// Add only the dependencies required for `Config.simd` enabled. This also
/// adds all the simd source files for compilation.
pub fn addSimd(
    b: *std.Build,
    m: *std.Build.Module,
    static_libs: ?*LazyPathList,
) !void {
    const target = m.resolved_target.?;
    const optimize = m.optimize.?;
    const system_highway = b.systemIntegrationOption("highway", .{ .default = false });

    // Simdutf
    if (b.systemIntegrationOption("simdutf", .{})) {
        m.linkSystemLibrary("simdutf", dynamic_link_opts);
    } else {
        if (b.lazyDependency("simdutf", .{
            .target = target,
            .optimize = optimize,
            .no_libcxx = true,
        })) |simdutf_dep| {
            m.linkLibrary(simdutf_dep.artifact("simdutf"));
            if (static_libs) |v| try v.append(
                b.allocator,
                simdutf_dep.artifact("simdutf").getEmittedBin(),
            );
        }
    }

    // Highway
    if (system_highway) {
        m.linkSystemLibrary("libhwy", dynamic_link_opts);
    } else {
        if (b.lazyDependency("highway", .{
            .target = target,
            .optimize = optimize,
        })) |highway_dep| {
            m.linkLibrary(highway_dep.artifact("highway"));
            if (static_libs) |v| try v.append(
                b.allocator,
                highway_dep.artifact("highway").getEmittedBin(),
            );
        }
    }

    // SIMD C++ files
    m.addIncludePath(b.path("src"));
    {
        // From hwy/detect_targets.h
        const HWY_AVX10_2: c_int = 1 << 3;
        const HWY_AVX3_SPR: c_int = 1 << 4;
        const HWY_AVX3_ZEN4: c_int = 1 << 6;
        const HWY_AVX3_DL: c_int = 1 << 7;
        const HWY_AVX3: c_int = 1 << 8;

        var flags: std.ArrayListUnmanaged([]const u8) = .empty;

        // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
        // To workaround this we just disable AVX512 support completely.
        // The performance difference between AVX2 and AVX512 is not
        // significant for our use case and AVX512 is very rare on consumer
        // hardware anyways.
        const HWY_DISABLED_TARGETS: c_int = HWY_AVX10_2 | HWY_AVX3_SPR | HWY_AVX3_ZEN4 | HWY_AVX3_DL | HWY_AVX3;
        if (target.result.cpu.arch == .x86_64) try flags.append(
            b.allocator,
            b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
        );

        // MSVC requires explicit std specification otherwise these
        // are guarded, at least on Windows 2025. Doing it unconditionally
        // doesn't cause any issues on other platforms and ensures we get
        // C++17 support on MSVC.
        try flags.append(
            b.allocator,
            "-std=c++17",
        );

        // Keep our SIMD sources in the same Highway header mode as the
        // vendored package build so HWY's inline dispatch/runtime helpers
        // have a consistent ABI.
        if (!system_highway) try flags.append(
            b.allocator,
            "-DHWY_NO_LIBCXX",
        );

        // When using the vendored simdutf, build its headers in no-libcxx
        // mode so we don't need C++ standard library headers at all.
        // System simdutf headers may not support this define.
        if (!b.systemIntegrationOption("simdutf", .{})) try flags.append(
            b.allocator,
            "-DSIMDUTF_NO_LIBCXX",
        );

        m.addCSourceFiles(.{
            .files = &.{
                "src/simd/base64.cpp",
                "src/simd/codepoint_width.cpp",
                "src/simd/index_of.cpp",
                "src/simd/vt.cpp",
            },
            .flags = flags.items,
        });
    }
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
