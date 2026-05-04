const std = @import("std");
const config = @import("config.zig");
const log_store = @import("log_store.zig");
const supervisor_mod = @import("supervisor.zig");

pub const PlainRunError = error{
    ChildFailed,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    profile: *const config.ResolvedProfile,
    options: supervisor_mod.Options,
) !void {
    var supervisor = try supervisor_mod.Supervisor.init(allocator, io, environ_map, profile, options);
    defer supervisor.deinit();

    supervisor.startAutostart();

    var printed_logs: usize = 0;
    while (true) {
        try supervisor.drainEvents();
        supervisor.tick();
        try printNewLogs(allocator, io, &supervisor, &printed_logs);

        if (!supervisor.hasActiveProcess()) break;
        try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    }

    try supervisor.drainEvents();
    try printNewLogs(allocator, io, &supervisor, &printed_logs);

    if (supervisor.hasFailedProcess()) return error.ChildFailed;
}

fn printNewLogs(
    allocator: std.mem.Allocator,
    io: std.Io,
    supervisor: *supervisor_mod.Supervisor,
    printed_logs: *usize,
) !void {
    const logs = try supervisor.global_logs.snapshot(allocator);
    defer if (logs.len > 0) allocator.free(logs);

    const start = @min(printed_logs.*, logs.len);
    for (logs[start..]) |line| {
        try printLogLine(io, line);
    }
    printed_logs.* = logs.len;
}

fn printLogLine(io: std.Io, line: log_store.LogLine) !void {
    var buffer: [4096]u8 = undefined;
    const file = switch (line.stream) {
        .stderr => std.Io.File.stderr(),
        .stdout, .system => std.Io.File.stdout(),
    };
    var writer = file.writer(io, &buffer);
    const time = formatTime(line.timestamp_ms);
    try writer.interface.print("{s} [{s}:{s}] {s}\n", .{
        &time,
        line.process_name,
        @tagName(line.stream),
        line.text,
    });
    try writer.interface.flush();
}

fn formatTime(timestamp_ms: i64) [8]u8 {
    const total_seconds: i64 = @mod(@divFloor(timestamp_ms, 1000), 24 * 60 * 60);
    const hour: u8 = @intCast(@divFloor(total_seconds, 3600));
    const minute: u8 = @intCast(@divFloor(@mod(total_seconds, 3600), 60));
    const second: u8 = @intCast(@mod(total_seconds, 60));
    return .{
        '0' + hour / 10,
        '0' + hour % 10,
        ':',
        '0' + minute / 10,
        '0' + minute % 10,
        ':',
        '0' + second / 10,
        '0' + second % 10,
    };
}

test "plain_format_time" {
    try std.testing.expectEqualStrings("01:02:03", &formatTime(((60 * 60) + (2 * 60) + 3) * 1000));
}
