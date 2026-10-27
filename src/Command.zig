//! Command launches sub-processes. This is an alternate implementation to the
//! Zig std.process.Child since at the time of authoring this, std.process.Child
//! didn't support the options necessary to spawn a shell attached to a pty.
//!
//! Consequently, I didn't implement a lot of features that std.process.Child
//! supports because we didn't need them. Cross-platform subprocessing is not
//! a trivial thing to implement (I've done it in three separate languages now)
//! so if we want to replatform onto std.process.Child I'd love to do that.
//! This was just the fastest way to get something built.
//!
//! Issues with std.process.Child:
//!
//!   * No pre_exec callback for logic after fork but before exec.
//!   * posix_spawn is used for Mac, but doesn't support the necessary
//!     features for tty setup.
//!
//!
//! TODO: This may have changed a lot now with the new I/O implementations in
//! >= 0.16.0, so this might warrant a recheck.
const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const configpkg = @import("config.zig");
const global = @import("global.zig");
const internal_os = @import("os/main.zig");
const TempDir = internal_os.TempDir;
const mem = std.mem;
const posix = std.posix;
const debug = std.debug;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const File = std.Io.File;
const EnvMap = std.process.Environ.Map;
const apprt = @import("apprt.zig");

/// Function prototype for a function executed /in the child process/ after the
/// fork, but before exec'ing the command. If the function returns a u8, the
/// child process will be exited with that error code.
const PreExecFn = fn (*Command) ?u8;

/// Allowable set of errors that can be returned by a post fork function. Any
/// errors will result in the failure to create the surface.
pub const PostForkError = error{PostForkError};

/// Function prototype for a function executed /in the parent process/
/// after the fork.
const PostForkFn = fn (*Command) PostForkError!void;

/// Path to the command to run. This doesn't have to be an absolute path,
/// because use exec functions that search the PATH, if necessary.
///
/// This field is null-terminated to avoid a copy for the sake of
/// adding a null terminator since POSIX systems are so common.
path: [:0]const u8,

/// Command-line arguments. It is the responsibility of the caller to set
/// args[0] to the command. If args is empty then args[0] will automatically
/// be set to equal path.
args: []const [:0]const u8,

/// Environment variables for the child process. If this is null, inherits
/// the environment variables from this process. These are the exact
/// environment variables to set; these are /not/ merged.
env: ?*const EnvMap = null,

/// Working directory to change to in the child process. If not set, the
/// working directory of the calling process is preserved.
cwd: ?[:0]const u8 = null,

/// The file handle to set for stdin/out/err. If this isn't set, we do
/// nothing explicitly so it is up to the behavior of the operating system.
stdin: ?File = null,
stdout: ?File = null,
stderr: ?File = null,

/// If set, this will be executed /in the child process/ after fork but
/// before exec. This is useful to setup some state in the child before the
/// exec process takes over, such as signal handlers, setsid, setuid, etc.
os_pre_exec: ?*const PreExecFn,

/// If set, this will be executed /in the child process/ after fork but
/// before exec. This is useful to setup some state in the child before the
/// exec process takes over, such as signal handlers, setsid, setuid, etc.
rt_pre_exec: ?*const PreExecFn,

/// Configuration information needed by the apprt pre exec function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
rt_pre_exec_info: RtPreExecInfo,

/// If set, this will be executed in the /in the parent process/ after the fork.
rt_post_fork: ?*const PostForkFn,

/// Configuration information needed by the apprt post fork function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
rt_post_fork_info: RtPostForkInfo,

/// User data that is sent to the callback. Set with setData and getData
/// for a more user-friendly API.
data: ?*anyopaque = null,

/// Process ID is set after start is called.
pid: ?posix.system.pid_t = null,

/// The various methods a process may exit.
pub const Exit = union(enum) {
    /// Exited by normal exit call, value is exit status
    Exited: u8,

    /// Exited by a signal, value is the signal
    Signal: u32,

    /// Exited by a stop signal, value is signal
    Stopped: u32,

    /// Unknown exit reason, value is the status from waitpid
    Unknown: u32,

    pub fn init(status: u32) Exit {
        return if (posix.W.IFEXITED(status))
            Exit{ .Exited = posix.W.EXITSTATUS(status) }
        else if (posix.W.IFSIGNALED(status))
            Exit{ .Signal = @backingInt(posix.W.TERMSIG(status)) }
        else if (posix.W.IFSTOPPED(status))
            Exit{ .Stopped = @backingInt(posix.W.STOPSIG(status)) }
        else
            Exit{ .Unknown = status };
    }
};

/// Configuration information needed by the apprt pre exec function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
pub const RtPreExecInfo = if (@hasDecl(apprt.runtime, "pre_exec")) apprt.runtime.pre_exec.PreExecInfo else struct {
    pub inline fn init(_: *const configpkg.Config) @This() {
        return .{};
    }
};

/// Configuration information needed by the apprt post fork function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
pub const RtPostForkInfo = if (@hasDecl(apprt.runtime, "post_fork")) apprt.runtime.post_fork.PostForkInfo else struct {
    pub inline fn init(_: *const configpkg.Config) @This() {
        return .{};
    }
};

/// Start the subprocess. This returns immediately once the child is started.
///
/// After this is successful, self.pid is available.
pub fn start(self: *Command, alloc: Allocator) !void {
    // Use an arena allocator for the temporary allocations we need in this func.
    // IMPORTANT: do all allocation prior to the fork(). I believe it is undefined
    // behavior if you malloc between fork and exec. The source of the Zig
    // stdlib seems to verify this as well as Go.
    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    try self.startPosix(arena);
}

fn startPosix(self: *Command, arena: Allocator) !void {
    // Null-terminate all our arguments
    const argsZ = try arena.allocSentinel(?[*:0]const u8, self.args.len, null);
    for (self.args, 0..) |arg, i| argsZ[i] = arg.ptr;

    // Determine our env vars
    const envp = if (self.env) |env_map|
        (try createNullDelimitedEnvMap(arena, env_map)).ptr
    else if (builtin.link_libc)
        std.c.environ
    else
        @compileError("missing env vars");

    // Fork.
    const pid = try fork();

    if (pid != 0) {
        // Parent, return immediately.
        self.pid = @intCast(pid);
        if (self.rt_post_fork) |f| try f(self);
        return;
    }

    // We are the child.

    // Setup our file descriptors for std streams.
    if (self.stdin) |f| setupFd(f.handle, posix.STDIN_FILENO) catch
        return error.ExecFailedInChild;
    if (self.stdout) |f| setupFd(f.handle, posix.STDOUT_FILENO) catch
        return error.ExecFailedInChild;
    if (self.stderr) |f| setupFd(f.handle, posix.STDERR_FILENO) catch
        return error.ExecFailedInChild;

    // Setup our working directory.
    //
    // NOTE: this can fail if we don't have permission to go to this directory
    // or if due to race conditions it doesn't exist or any various other
    // reasons. We don't want to crash the entire process if this fails so we
    // ignore it. We don't log because that'll show up in the output.
    if (self.cwd) |cwd| _ = posix.system.chdir(cwd);

    // Restore any rlimits that were set by Nubb. This might fail but
    // any failures are ignored (its best effort).
    global.rlimits().restore();

    // If there are pre exec callbacks, call them now.
    if (self.os_pre_exec) |f| if (f(self)) |exitcode| posix.system.exit(exitcode);
    if (self.rt_pre_exec) |f| if (f(self)) |exitcode| posix.system.exit(exitcode);

    const err: posix.E = execve: {
        // This functionality has been taken from Zig stdlib, a simplified
        // version of the exec bits with PATH search so that we can just
        // offload to execve below.
        const file_slice = std.mem.sliceTo(self.path, 0);
        if (std.mem.findScalar(u8, file_slice, '/') != null) {
            break :execve posix.errno(posix.system.execve(self.path, argsZ, envp));
        }

        var path_expanded_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const PATH = global.environ().getPosix("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
        var it = std.mem.tokenizeScalar(u8, PATH, ':');
        var err: posix.system.E = .NOENT;
        var seen_eacces = false;

        while (it.next()) |search_path| {
            const path_len = search_path.len + file_slice.len + 1;
            if (path_expanded_buf.len < path_len + 1) break :execve .NAMETOOLONG;
            @memcpy(path_expanded_buf[0..search_path.len], search_path);
            path_expanded_buf[search_path.len] = '/';
            @memcpy(path_expanded_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
            path_expanded_buf[path_len] = 0;
            const full_path = path_expanded_buf[0..path_len :0].ptr;
            // Replace here, switch on error (any error means that replace
            // failed, but we might need to retry).
            err = posix.errno(posix.system.execve(full_path, argsZ, envp));
            switch (err) {
                .ACCES => seen_eacces = true,
                .NOENT, .NOTDIR => {},
                else => break :execve err,
            }
        }

        if (seen_eacces) break :execve .ACCES;
        break :execve err;
    };

    // If we are executing this code, the exec failed. We're in the
    // child process so there isn't much we can do. We try to output
    // something reasonable. Its important to note we MUST NOT return
    // any other error condition from here on out.
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &stderr_buf);
    const stderr = &stderr_writer.interface;
    switch (err) {
        posix.system.E.NOENT => stderr.print(
            \\Requested executable not found. Please verify the command is on
            \\the PATH and try again.
            \\
        ,
            .{},
        ) catch {},

        else => |e| stderr.print(
            \\exec syscall failed with unexpected error: E{s}
            \\
        ,
            .{@tagName(e)},
        ) catch {},
    }
    stderr.flush() catch {};

    // We return a very specific error that can be detected to determine
    // we're in the child.
    return error.ExecFailedInChild;
}

/// Wrapper for the raw fork syscall. This preserves the error handling from
/// the std.posix wrapper that was removed in Zig 0.16.
fn fork() !posix.pid_t {
    const rc = posix.system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN, .NOMEM => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn setupFd(src: File.Handle, target: i32) !void {
    const PosixCall = struct {
        fn f(func: anytype, args: anytype) !usize {
            while (true) {
                const rc = @call(.auto, func, args);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN, .ACCES => return error.Locked,
                    .BADF => unreachable,
                    .BUSY => return error.FileBusy,
                    .INVAL => unreachable, // invalid parameters
                    .PERM => return error.PermissionDenied,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NOTDIR => unreachable, // invalid parameter
                    .DEADLK => return error.DeadLock,
                    .NOLCK => return error.LockedRegionLimitExceeded,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        }
    };

    switch (builtin.target.os.tag) {
        .ios, .macos => {
            // Mac doesn't support dup3 so we use dup2. We purposely clear
            // CLO_ON_EXEC for this fd.
            const flags = try PosixCall.f(posix.system.fcntl, .{ src, posix.F.GETFD });
            if (flags & posix.FD_CLOEXEC != 0) {
                _ = try PosixCall.f(
                    posix.system.fcntl,
                    .{ src, posix.F.SETFD, flags & ~@as(u32, posix.FD_CLOEXEC) },
                );
            }

            _ = try PosixCall.f(posix.system.dup2, .{ src, target });
        },
        else => @compileError("unsupported platform"),
    }
}

/// Wait for the command to exit and return information about how it exited.
pub fn wait(self: Command, block: bool) !Exit {
    const status: u32 = if (block) wait_block: {
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        _ = try waitPid(self.pid.?, &status, 0);
        break :wait_block @bitCast(status);
    } else wait_nohang: {
        // We specify NOHANG because its not our fault if the process we launch
        // for the tty doesn't properly waitpid its children. We don't want
        // to hang the terminal over it.
        // When NOHANG is specified, waitpid will return a pid of 0 if the process
        // doesn't have a status to report. When that happens, it is as though the
        // wait call has not been performed, so we need to keep trying until we get
        // a non-zero pid back, otherwise we end up with zombie processes.
        while (true) {
            var status: if (builtin.link_libc) c_int else u32 = undefined;
            const pid = try waitPid(self.pid.?, &status, posix.system.W.NOHANG);
            if (pid != 0) break :wait_nohang @bitCast(status);
        }
    };

    return .init(status);
}

/// Wrapper for the raw waitpid syscall. Status is only initialized on success;
/// interrupted waits are retried and all other errors are propagated.
fn waitPid(
    pid: posix.pid_t,
    status: *if (builtin.link_libc) c_int else u32,
    flags: u32,
) !posix.pid_t {
    while (true) {
        const rc = posix.system.waitpid(pid, status, @intCast(flags));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .CHILD => return error.NoChildProcess,
            .INVAL => return error.InvalidWaitOptions,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Sets command->data to data.
pub fn setData(self: *Command, pointer: ?*anyopaque) void {
    self.data = pointer;
}

/// Returns command->data.
pub fn getData(self: Command, comptime DT: type) ?*DT {
    return if (self.data) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

// Copied from Zig. This is a publicly exported function but there is no
// way to get it from the std package.
fn createNullDelimitedEnvMap(arena: mem.Allocator, env_map: *const EnvMap) ![:null]?[*:0]u8 {
    const envp_count = env_map.count();
    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);

    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| : (i += 1) {
        const env_buf = try arena.allocSentinel(u8, pair.key_ptr.len + pair.value_ptr.len + 1, 0);
        @memcpy(env_buf[0..pair.key_ptr.len], pair.key_ptr.*);
        env_buf[pair.key_ptr.len] = '=';
        @memcpy(env_buf[pair.key_ptr.len + 1 ..], pair.value_ptr.*);
        envp_buf[i] = env_buf.ptr;
    }
    std.debug.assert(i == envp_count);

    return envp_buf;
}

test "createNullDelimitedEnvMap" {
    const allocator = testing.allocator;
    var envmap = EnvMap.init(allocator);
    defer envmap.deinit();

    try envmap.put("HOME", "/home/ifreund");
    try envmap.put("WAYLAND_DISPLAY", "wayland-1");
    try envmap.put("DISPLAY", ":1");
    try envmap.put("DEBUGINFOD_URLS", " ");
    try envmap.put("XCURSOR_SIZE", "24");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const environ = try createNullDelimitedEnvMap(arena.allocator(), &envmap);

    try testing.expectEqual(@as(usize, 5), environ.len);

    inline for (.{
        "HOME=/home/ifreund",
        "WAYLAND_DISPLAY=wayland-1",
        "DISPLAY=:1",
        "DEBUGINFOD_URLS= ",
        "XCURSOR_SIZE=24",
    }) |target| {
        for (environ) |variable| {
            if (mem.eql(u8, mem.span(variable orelse continue), target)) break;
        } else {
            try testing.expect(false); // Environment variable not found
        }
    }
}

test "Command: os pre exec 1" {
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                posix.system.exit(42);
            }
        }).do,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: os pre exec 2" {
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                return 42;
            }
        }).do,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt pre exec 1" {
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = null,
        .rt_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                posix.system.exit(42);
            }
        }).do,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt pre exec 2" {
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = null,
        .rt_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                return 42;
            }
        }).do,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt post fork 1" {
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "sleep 1" },
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = (struct {
            fn do(_: *Command) PostForkError!void {
                return error.PostForkError;
            }
        }).do,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try testing.expectError(error.PostForkError, cmd.testingStart());
}

fn createTestStdout(io: std.Io, dir: std.Io.Dir) !File {
    const file = try dir.createFile(io, "stdout.txt", .{ .read = true });
    return file;
}

fn createTestStderr(io: std.Io, dir: std.Io.Dir) !File {
    const file = try dir.createFile(io, "stderr.txt", .{ .read = true });
    return file;
}

test "Command: redirect stdout to file" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);

    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "echo hello" },
        .stdout = stdout,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expectEqual(@as(u32, 0), @as(u32, exit.Exited));

    // Read our stdout
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);
    try testing.expect(contents.len > 0);
}

test "Command: custom env vars" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("VALUE", "hello");

    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "echo $VALUE" },
        .stdout = stdout,
        .env = &env,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);

    // Read our stdout
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);

    try testing.expectEqualStrings("hello\n", contents);
}

test "Command: custom working directory" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);

    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "pwd" },
        .stdout = stdout,
        .cwd = "/tmp",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);

    // Read our stdout
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);

    if (builtin.target.os.tag == .macos) {
        try testing.expectEqualStrings("/private/tmp\n", contents);
    } else {
        try testing.expectEqualStrings("/tmp\n", contents);
    }
}

// Test validate an execveZ failure correctly terminates when error.ExecFailedInChild is correctly handled
//
// Incorrectly handling an error.ExecFailedInChild results in a second copy of the test process running.
// Duplicating the test process leads to weird behavior
// zig build test will hang
// test binary created via -Demit-test-exe will run 2 copies of the test suite
test "Command: posix fork handles execveZ failure" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);
    var stderr = try createTestStderr(testing.io, td.dir);
    defer stderr.close(testing.io);

    var cmd: Command = .{
        .path = "/not/a/binary",
        .args = &.{ "/not/a/binary", "" },
        .stdout = stdout,
        .stderr = stderr,
        .cwd = "/bin",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 1);
}

// If cmd.start fails with error.ExecFailedInChild it's the _child_ process that is running. If it does not
// terminate in response to that error both the parent and child will continue as if they _are_ the test suite
// process.
fn testingStart(self: *Command) !void {
    self.start(testing.allocator) catch |err| {
        if (err == error.ExecFailedInChild) {
            // I am a child process, I must not get confused and continue running the rest of the test suite.
            posix.system.exit(1);
        }
        return err;
    };
}
