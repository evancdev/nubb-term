//! A library represents the shared state that the underlying font
//! library implementation(s) require per-process. CoreText needs no
//! such state, so this is a no-op kept so callers have one place to
//! hang per-process font state if it is ever needed.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Library = struct {
    pub const InitError = error{};

    pub fn init(alloc: Allocator) InitError!Library {
        _ = alloc;
        return Library{};
    }

    pub fn deinit(self: *Library) void {
        _ = self;
    }
};
