const std = @import("std");
const builtin = @import("builtin");

pub const ProcessTree = struct {
    handle: if (builtin.os.tag == .windows) ?std.os.windows.HANDLE else void = if (builtin.os.tag == .windows) null else {},

    pub fn init() ProcessTree {
        var tree: ProcessTree = .{};
        if (builtin.os.tag == .windows) {
            const handle = windowsCreateJobObjectW(null, null) orelse return tree;
            tree.handle = handle;
            configureWindowsJob(handle);
        }
        return tree;
    }

    pub fn empty() ProcessTree {
        return .{};
    }

    pub fn shouldStartSuspended(self: *const ProcessTree) bool {
        return switch (builtin.os.tag) {
            .windows => self.handle != null,
            else => false,
        };
    }

    pub fn attach(self: *ProcessTree, pid: std.process.Child.Id) void {
        if (builtin.os.tag != .windows) {
            return;
        }
        const handle = self.handle orelse return;
        if (!windowsAssignProcessToJobObject(handle, pid).toBool()) {
            std.os.windows.CloseHandle(handle);
            self.handle = null;
        }
    }

    pub fn terminate(self: *ProcessTree, exit_code: u32) bool {
        if (builtin.os.tag != .windows) {
            return false;
        }
        const handle = self.handle orelse return false;
        return windowsTerminateJobObject(handle, @intCast(exit_code)).toBool();
    }

    pub fn close(self: *ProcessTree) void {
        if (builtin.os.tag != .windows) {
            return;
        }
        if (self.handle) |handle| {
            std.os.windows.CloseHandle(handle);
            self.handle = null;
        }
    }
};

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

pub fn resumeChild(child: *std.process.Child) void {
    if (builtin.os.tag != .windows) {
        return;
    }
    switch (std.os.windows.ntdll.NtResumeThread(child.thread_handle, null)) {
        .SUCCESS => {},
        else => {},
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

const WindowsJobObjectInfoClass = enum(c_int) {
    extended_limit_information = 9,
};

const WindowsJobObjectBasicLimitInformation = extern struct {
    per_process_user_time_limit: i64 = 0,
    per_job_user_time_limit: i64 = 0,
    limit_flags: u32 = 0,
    minimum_working_set_size: usize = 0,
    maximum_working_set_size: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};

const WindowsIoCounters = extern struct {
    read_operation_count: u64 = 0,
    write_operation_count: u64 = 0,
    other_operation_count: u64 = 0,
    read_transfer_count: u64 = 0,
    write_transfer_count: u64 = 0,
    other_transfer_count: u64 = 0,
};

const WindowsJobObjectExtendedLimitInformation = extern struct {
    basic_limit_information: WindowsJobObjectBasicLimitInformation = .{},
    io_info: WindowsIoCounters = .{},
    process_memory_limit: usize = 0,
    job_memory_limit: usize = 0,
    peak_process_memory_used: usize = 0,
    peak_job_memory_used: usize = 0,
};

const windows_job_object_limit_kill_on_job_close: u32 = 0x0000_2000;

fn configureWindowsJob(handle: std.os.windows.HANDLE) void {
    if (builtin.os.tag != .windows) unreachable;

    var info: WindowsJobObjectExtendedLimitInformation = .{};
    info.basic_limit_information.limit_flags = windows_job_object_limit_kill_on_job_close;
    _ = windowsSetInformationJobObject(
        handle,
        .extended_limit_information,
        &info,
        @intCast(@sizeOf(WindowsJobObjectExtendedLimitInformation)),
    );
}

extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*anyopaque,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn AssignProcessToJobObject(
    hJob: std.os.windows.HANDLE,
    hProcess: std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn TerminateJobObject(
    hJob: std.os.windows.HANDLE,
    uExitCode: std.os.windows.UINT,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn SetInformationJobObject(
    hJob: std.os.windows.HANDLE,
    jobObjectInfoClass: WindowsJobObjectInfoClass,
    lpJobObjectInfo: *const WindowsJobObjectExtendedLimitInformation,
    cbJobObjectInfoLength: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

fn windowsCreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?[*:0]const u16) ?std.os.windows.HANDLE {
    if (builtin.os.tag != .windows) unreachable;
    return CreateJobObjectW(lpJobAttributes, lpName);
}

fn windowsAssignProcessToJobObject(hJob: std.os.windows.HANDLE, hProcess: std.os.windows.HANDLE) std.os.windows.BOOL {
    if (builtin.os.tag != .windows) unreachable;
    return AssignProcessToJobObject(hJob, hProcess);
}

fn windowsTerminateJobObject(hJob: std.os.windows.HANDLE, exit_code: std.os.windows.UINT) std.os.windows.BOOL {
    if (builtin.os.tag != .windows) unreachable;
    return TerminateJobObject(hJob, exit_code);
}

fn windowsSetInformationJobObject(
    hJob: std.os.windows.HANDLE,
    class: WindowsJobObjectInfoClass,
    info: *const WindowsJobObjectExtendedLimitInformation,
    len: std.os.windows.DWORD,
) std.os.windows.BOOL {
    if (builtin.os.tag != .windows) unreachable;
    return SetInformationJobObject(hJob, class, info, len);
}
