const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const objc = @import("objc");

const log = std.log.scoped(.os_locale);

/// Ensure that the locale is set.
pub fn ensureLocale() !void {
    // This does a lot of in-process mutation of the environment and can't be
    // run in a test as a result.
    assert(!builtin.is_test);

    // On macOS, pre-populate the LANG env var with system preferences.
    // When launching the .app, LANG is not set so we must query it from the
    // OS. When launching from the CLI, LANG is usually set by the parent
    // process.
    if (comptime builtin.target.os.tag.isDarwin()) {
        // Set the lang if it is not set or if its empty.
        const lang = std.posix.system.getenv("LANG");
        if (lang == null or lang.?[0] == 0) {
            setLangFromCocoa();
        }
    }

    // Set the locale to whatever is set in env vars.
    if (setlocale(LC_ALL, "")) |v| {
        log.info("setlocale from env result={s}", .{v});
        return;
    }

    // setlocale failed. This is probably because the LANG env var is
    // invalid. Try to set it without the LANG var set to use the system
    // default.
    if (std.posix.system.getenv("LANG")) |lang| {
        if (lang[0] != 0) {
            // We don't need to do both of these things but we do them
            // both to be sure that lang is either empty or unset completely.
            _ = setenv("LANG", "", 1);
            _ = unsetenv("LANG");

            if (setlocale(LC_ALL, "")) |v| {
                log.info("setlocale after unset lang result={s}", .{v});

                // If we try to setlocale to an unsupported locale it'll return "C"
                // as the POSIX/C fallback, if that's the case we want to not use
                // it and move to our fallback of en_US.UTF-8
                if (!std.mem.eql(u8, std.mem.sliceTo(v, 0), "C")) return;
            }
        }
    }

    // Failure again... fallback to en_US.UTF-8
    log.warn("setlocale failed with LANG and system default. Falling back to en_US.UTF-8", .{});
    if (setlocale(LC_ALL, "en_US.UTF-8")) |v| {
        _ = setenv("LANG", "en_US.UTF-8", 1);
        log.info("setlocale default result={s}", .{v});
        return;
    } else log.warn("setlocale failed even with the fallback, uncertain results", .{});
}

/// This sets the LANG environment variable based on the macOS system
/// preferences selected locale settings.
fn setLangFromCocoa() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // The classes we're going to need.
    const NSLocale = objc.getClass("NSLocale") orelse {
        log.warn("NSLocale class not found. Locale may be incorrect.", .{});
        return;
    };

    // Get our current locale and extract the language code ("en") and
    // country code ("US")
    const locale = NSLocale.msgSend(objc.Object, objc.sel("currentLocale"), .{});
    const lang = locale.getProperty(objc.Object, "languageCode");
    const country = locale.getProperty(objc.Object, "countryCode");

    if (lang.value == null or country.value == null) {
        log.warn("languageCode or countryCode not found. Locale may be incorrect.", .{});
        return;
    }

    // Get our UTF8 string values
    const c_lang = lang.getProperty([*:0]const u8, "UTF8String");
    const c_country = country.getProperty([*:0]const u8, "UTF8String");

    // Convert them to Zig slices
    const z_lang = std.mem.sliceTo(c_lang, 0);
    const z_country = std.mem.sliceTo(c_country, 0);

    // Format our locale as "<lang>_<country>.UTF-8" and set it as LANG.
    {
        var buf: [128]u8 = undefined;
        const env_value = std.mem.printSentinel(&buf, "{s}_{s}.UTF-8", .{ z_lang, z_country }, 0) catch |err| {
            log.warn("error setting locale from system. err={}", .{err});
            return;
        };
        log.info("detected system locale={s}", .{env_value});

        // Set it onto our environment
        if (setenv("LANG", @ptrCast(env_value), 1) < 0) {
            log.warn("error setting locale env var", .{});
            return;
        }
    }
}

const c = @import("locale-c");
const LC_ALL: c_int = c.LC_ALL;
const LC_ALL_MASK: c_int = c.LC_ALL_MASK;
const locale_t = c.locale_t;
const setlocale = c.setlocale;
const newlocale = c.newlocale;
const freelocale = c.freelocale;

extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: ?[*]const u8) c_int;
