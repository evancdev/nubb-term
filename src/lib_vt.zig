//! This is the public API of the ghostty-vt Zig module.
//!
//! WARNING: The API is not guaranteed to be stable.
//!
//! The functionality is extremely stable, since it is extracted
//! directly from Ghostty which has been used in real world scenarios
//! by thousands of users for years. However, the API itself (functions,
//! types, etc.) may change without warning. We're working on stabilizing
//! this in the future.
const lib = @This();

const std = @import("std");
const builtin = @import("builtin");
const stderr = @import("os/stderr.zig");

// The public API below reproduces a lot of terminal/main.zig but
// is separate because (1) we need our root file to be in `src/`
// so we can access other directories and (2) we may want to withhold
// parts of `terminal` that are not ready for public consumption
// or are too Ghostty-internal.
const terminal = @import("terminal/main.zig");

/// System interface for the terminal package.
///
/// This module provides runtime-swappable function pointers for operations
/// that depend on external implementations. Embedders can use this to
/// provide or override default behaviors. These must be set at startup
/// before any terminal functionality is used.
///
/// This lets libghostty-vt have no runtime dependencies on external
/// libraries, while still allowing rich functionality that may require
/// external libraries (e.g. image decoding or regular expresssions).
///
/// Setting these will enable various features of the terminal package.
/// For example, setting a PNG decoder will enable support for PNG images in
/// the Kitty Graphics Protocol.
///
/// Additional functionality will be added here over time as needed.
pub const sys = terminal.sys;

pub const apc = terminal.apc;
pub const clipboard = terminal.clipboard;
pub const dcs = terminal.dcs;
pub const osc = terminal.osc;
pub const point = terminal.point;
pub const color = terminal.color;
pub const xt_checksum = terminal.xt_checksum;
pub const device_attributes = terminal.device_attributes;
pub const device_status = terminal.device_status;
pub const formatter = terminal.formatter;
pub const highlight = terminal.highlight;
pub const kitty = terminal.kitty;
pub const modes = terminal.modes;
pub const page = terminal.page;
pub const parse_table = terminal.parse_table;
pub const search = terminal.search;
pub const sgr = terminal.sgr;
pub const size = terminal.size;
pub const x11_color = terminal.x11_color;

pub const Charset = terminal.Charset;
pub const CharsetSlot = terminal.CharsetSlot;
pub const CharsetActiveSlot = terminal.CharsetActiveSlot;
pub const Cell = page.Cell;
pub const Coordinate = point.Coordinate;
pub const CSI = Parser.Action.CSI;
pub const DCS = Parser.Action.DCS;
pub const MouseShape = terminal.MouseShape;
pub const Page = page.Page;
pub const PageList = terminal.PageList;
pub const Parser = terminal.Parser;
pub const Pin = PageList.Pin;
pub const Point = point.Point;
pub const RenderState = terminal.RenderState;
pub const Screen = terminal.Screen;
pub const ScreenSet = terminal.ScreenSet;
pub const Selection = terminal.Selection;
pub const SelectionGesture = terminal.SelectionGesture;
pub const size_report = terminal.size_report;
pub const SizeReportStyle = terminal.SizeReportStyle;
pub const StringMap = terminal.StringMap;
pub const Style = terminal.Style;
pub const Terminal = terminal.Terminal;
pub const TerminalStream = terminal.TerminalStream;
pub const Stream = terminal.Stream;
pub const StreamAction = terminal.StreamAction;
pub const StreamBoundary = terminal.StreamBoundary;
pub const SemanticPrompt = terminal.SemanticPrompt;
pub const UnknownSequence = terminal.UnknownSequence;

pub const Paste = terminal.Paste;
pub const PasteSource = terminal.PasteSource;
pub const PasteError = terminal.PasteError;
pub const Cursor = Screen.Cursor;
pub const CursorStyle = Screen.CursorStyle;
pub const CursorStyleReq = terminal.CursorStyle;
pub const DeviceAttributeReq = terminal.DeviceAttributeReq;
pub const Mode = modes.Mode;
pub const ModePacked = modes.ModePacked;
pub const ModifyKeyFormat = terminal.ModifyKeyFormat;
pub const ProtectedMode = terminal.ProtectedMode;
pub const StatusLineType = terminal.StatusLineType;
pub const StatusDisplay = terminal.StatusDisplay;
pub const EraseDisplay = terminal.EraseDisplay;
pub const EraseLine = terminal.EraseLine;
pub const TabClear = terminal.TabClear;
pub const Attribute = terminal.Attribute;

/// Terminal-specific input encoding is also part of libghostty-vt.
pub const input = struct {
    // We have to be careful to only import targeted files within
    // the input package because the full package brings in too many
    // other dependencies.
    const focus = terminal.focus;
    const paste = @import("input/paste.zig");
    const key = @import("input/key.zig");
    const key_encode = @import("input/key_encode.zig");
    const mouse_encode = @import("input/mouse_encode.zig");

    // Focus-related APIs
    pub const max_focus_encode_size = focus.max_encode_size;
    pub const FocusEvent = focus.Event;
    pub const encodeFocus = focus.encode;

    // Paste-related APIs
    pub const PasteError = paste.Error;
    pub const PasteOptions = paste.Options;
    pub const max_paste_frame_size = paste.max_frame_size;
    pub const isSafePaste = paste.isSafe;
    pub const isSafePasteWith = paste.isSafeWith;
    pub const encodePaste = paste.encode;
    pub const encodePasteWriter = paste.encodeWriter;

    // Key encoding
    pub const Key = key.Key;
    pub const KeyAction = key.Action;
    pub const KeyEvent = key.KeyEvent;
    pub const KeyMods = key.Mods;
    pub const KeyEncodeOptions = key_encode.Options;
    pub const encodeKey = key_encode.encode;

    // Mouse encoding
    pub const MouseAction = @import("input/mouse.zig").Action;
    pub const MouseButton = @import("input/mouse.zig").Button;
    pub const MouseEncodeOptions = mouse_encode.Options;
    pub const MouseEncodeEvent = mouse_encode.Event;
    pub const encodeMouse = mouse_encode.encode;
};

/// Unicode utilities that match the terminal's text layout semantics.
pub const unicode = struct {
    const unicode_pkg = @import("unicode/main.zig");

    pub const codepointWidth = unicode_pkg.codepointWidth;
    pub const graphemeWidth = unicode_pkg.graphemeWidth;
};

pub const std_options: std.Options = opts: {
    var options: std.Options = .{};

    if (builtin.target.os.tag.isDarwin() and builtin.target.os.tag != .macos) {
        // If are building for a non-MacOS Darwin target (e.g., iOS), we need to
        // disable stack tracing for the time being. This is due to the fact that
        // Zig switched to using _dyld_get_image_header_containing_address and some
        // other (deprecated) calls to speed up stack unwinding; these calls are
        // available on MacOS, but not on other platforms.
        //
        // A fix has already been submitted to exempt non-MacOS (but still Darwin)
        // targets, so this can likely be removed in Zig 0.17.0, or a 0.16.x patch
        // version if it releases beforehand.
        //
        // More details:
        //   https://codeberg.org/ziglang/zig/commit/89f86e46d278a35a613bbc662cdd3f65ffc76ed7
        //
        options.allow_stack_tracing = false;
    }

    break :opts options;
};

/// True for builds where we keep the full std debug machinery (stack
/// traces on panic, std.debug.print, etc.). These builds are for
/// development, where the roughly 160KB of binary size it costs is
/// worth it.
const debug_machinery: bool = builtin.is_test or switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => false,
};

/// The panic handler for when this file is the root module.
///
/// In ReleaseFast and ReleaseSmall builds we print the panic message to
/// stderr and trap, but do not attempt to unwind the stack to print a
/// stack trace.
pub const panic: type = if (debug_machinery)
    std.debug.FullPanic(std.debug.defaultPanic)
else
    std.debug.FullPanic(tinyPanicImpl);

/// Guards release builds against accidentally reintroducing the std
/// debug Io machinery.
///
/// `std.Options.debug_io` defaults to `std.Io.Threaded`, and anything
/// that reaches it (std.debug.print, std.debug.lockStderr, the default
/// std.log handler, etc.) pins Threaded's entire vtable into the binary:
/// roughly 110KB of unreachable code.
///
/// This verifies nothing ever touches it.
pub const std_options_debug_io: std.Io = if (debug_machinery)
    std.Io.Threaded.global_single_threaded.io()
else
    @compileError(
        \\The std debug Io machinery (std.debug.print, std.debug.lockStderr,
        \\std.log's default handler, ...) is disabled in libghostty-vt release
        \\builds because it costs ~110KB of binary size. Use std.log (routed
        \\through our logFn), os/stderr.zig for raw diagnostic writes, or
        \\gate the code on debug builds.
    );

/// Prints the panic message to stderr (best-effort) and traps.
///
/// This intentionally avoids `std.debug.lockStderr`, which routes through
/// `std.Options.debug_io` and would keep the entire `std.Io.Threaded`
/// vtable alive in the binary which takes up hundreds of KB.
///
/// This is safe to call from any thread (and even from signal handlers):
/// it takes no locks, performs no allocation, and touches no shared
/// mutable state. The message is emitted with a single raw write so that
/// concurrent stderr output doesn't interleave with it.
fn tinyPanicImpl(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    _ = ra;

    // 256 bytes is enough for most messages, so try that first
    // so that we can try to write in a single syscall.
    var buf: [256]u8 = undefined;
    if (std.mem.print(
        &buf,
        "panic: {s}\n",
        .{msg},
    )) |line| {
        stderr.write(line);
    } else |_| {
        stderr.write("panic: ");
        stderr.write(msg);
        stderr.write("\n");
    }

    // Trap forces a standard crash that embedder-provided debuggers
    // or environments can catch.
    @trap();
}

test {
    // Zig 0.16.0 has made test logging more strict. Now, *anything* that gets
    // printed to stderr results in a "failed command" message, even if the
    // tests ultimately passed. To reduce confusion here (and honestly, test
    // log spam in general), we bump the default testing log level to error.
    @import("std").testing.log_level = std.log.Level.err;

    _ = terminal;
    _ = @import("lib/main.zig");
    @import("std").testing.refAllDecls(input);
    @import("std").testing.refAllDecls(unicode);
}
