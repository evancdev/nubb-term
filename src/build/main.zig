//! Build logic for Nubb. A single "build.zig" file became far too complex
//! and spaghetti, so this package extracts the build logic into smaller,
//! more manageable pieces.

pub const Config = @import("Config.zig");
pub const GitVersion = @import("GitVersion.zig");

// Artifacts
pub const NubbBench = @import("NubbBench.zig");
pub const NubbLib = @import("NubbLib.zig");
pub const NubbResources = @import("NubbResources.zig");
pub const NubbXcodebuild = @import("NubbXcodebuild.zig");
pub const NubbXCFramework = @import("NubbXCFramework.zig");
pub const NubbZig = @import("NubbZig.zig");
pub const HelpStrings = @import("HelpStrings.zig");
pub const SharedDeps = @import("SharedDeps.zig");
pub const UnicodeTables = @import("UnicodeTables.zig");

// Steps
pub const LibtoolStep = @import("LibtoolStep.zig");
pub const LipoStep = @import("LipoStep.zig");
pub const MetallibStep = @import("MetallibStep.zig");
pub const XCFrameworkStep = @import("XCFrameworkStep.zig");

// Helpers
pub const requireZig = @import("zig.zig").requireZig;
