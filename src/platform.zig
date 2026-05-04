const std = @import("std");
const builtin = @import("builtin");

pub fn shellArgv(allocator: std.mem.Allocator, cmd: []const u8, shell_path: []const u8) ![]const []const u8 {
    if (builtin.os.tag == .windows) {
        var argv = try allocator.alloc([]const u8, 3);
        argv[0] = shell_path;
        argv[1] = "/C";
        argv[2] = cmd;
        return argv;
    }

    var argv = try allocator.alloc([]const u8, 3);
    argv[0] = shell_path;
    argv[1] = "-lc";
    argv[2] = cmd;
    return argv;
}

pub fn shellPath(parent_env: *const std.process.Environ.Map) []const u8 {
    return switch (builtin.os.tag) {
        .windows => parent_env.get("COMSPEC") orelse "cmd.exe",
        else => parent_env.get("SHELL") orelse "/bin/sh",
    };
}

pub fn directArgv(allocator: std.mem.Allocator, cmd: []const u8) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, 1);
    argv[0] = cmd;
    return argv;
}

pub fn childProcessGroupId() ?std.posix.pid_t {
    return switch (builtin.os.tag) {
        .windows, .wasi => null,
        else => 0,
    };
}

pub fn sendTerm(pid: std.process.Child.Id, process_group: bool) void {
    switch (builtin.os.tag) {
        .windows => terminateWindows(pid, 1),
        else => sendSignal(pid, process_group, .TERM),
    }
}

pub fn sendKill(pid: std.process.Child.Id, process_group: bool) void {
    switch (builtin.os.tag) {
        .windows => terminateWindows(pid, 1),
        else => sendSignal(pid, process_group, .KILL),
    }
}

fn sendSignal(pid: std.process.Child.Id, process_group: bool, signal: std.posix.SIG) void {
    const target = if (process_group) -pid else pid;
    std.posix.kill(target, signal) catch {
        std.posix.kill(pid, signal) catch {};
    };
}

pub fn pidToU64(pid: std.process.Child.Id) u64 {
    return switch (builtin.os.tag) {
        .windows => @intFromPtr(pid),
        .wasi => 0,
        else => @intCast(pid),
    };
}

fn terminateWindows(pid: std.process.Child.Id, exit_code: u32) void {
    if (builtin.os.tag != .windows) unreachable;

    const windows = std.os.windows;
    const status: windows.NTSTATUS = @enumFromInt(exit_code);
    _ = windows.ntdll.RtlReportSilentProcessExit(pid, status);
    switch (windows.ntdll.NtTerminateProcess(pid, status)) {
        .SUCCESS, .PROCESS_IS_TERMINATING, .ACCESS_DENIED => {},
        else => {},
    }
}
