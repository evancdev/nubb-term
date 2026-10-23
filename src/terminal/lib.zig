const std = @import("std");
const lib = @import("../lib/main.zig");

/// The target for the terminal lib in particular. Nubb never builds
/// the C library, so this is always the Zig ABI.
pub const target: lib.Target = .zig;

/// The calling convention to use for C APIs.
///
/// This is always .c for now. I want to make this "Zig" when we're not
/// building the C ABI but there are bigger issues we need to resolve to
/// make that possible (change it and see for yourself).
pub const calling_conv: std.lang.CallingConvention = .c;

/// Forwarded decls from lib that are used.
pub const Buffer = lib.Buffer;
pub const Enum = lib.Enum;
pub const parseInt = lib.parseInt;
pub const TaggedUnion = lib.TaggedUnion;
pub const Struct = lib.Struct;
pub const String = lib.String;
pub const checkGhosttyHEnum = lib.checkGhosttyHEnum;
pub const structSizedFieldFits = lib.structSizedFieldFits;
