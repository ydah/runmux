const std = @import("std");
const log_store = @import("log_store.zig");
const supervisor = @import("supervisor.zig");

pub const ProcessRowInput = struct {
    selected: bool,
    status: supervisor.ProcessStatus,
    critical: bool,
    name: []const u8,
    pid: ?u64,
    restart_count: u32,
    last_result: []const u8,
};

pub fn formatProcessRow(allocator: std.mem.Allocator, input: ProcessRowInput) ![]u8 {
    const pid_text = if (input.pid) |pid|
        try std.fmt.allocPrint(allocator, "{d}", .{pid})
    else
        try allocator.dupe(u8, "-");
    defer allocator.free(pid_text);

    return std.fmt.allocPrint(allocator, "{s} {s}{s} {s:<12} {s:<10} pid={s} r={d} {s}", .{
        if (input.selected) ">" else " ",
        statusGlyph(input.status),
        if (input.critical) "!" else " ",
        input.name,
        @tagName(input.status),
        pid_text,
        input.restart_count,
        input.last_result,
    });
}

pub fn formatLogPrefix(allocator: std.mem.Allocator, line: log_store.LogLine) ![]u8 {
    const time_text = try formatTimeAlloc(allocator, line.timestamp_ms);
    defer allocator.free(time_text);
    return std.fmt.allocPrint(allocator, "{s} [{s}:{s}] ", .{
        time_text,
        line.process_name,
        @tagName(line.stream),
    });
}

pub fn statusGlyph(status: supervisor.ProcessStatus) []const u8 {
    return switch (status) {
        .pending, .disabled, .exited => "o",
        .starting, .stopping => "~",
        .running => "*",
        .failed => "!",
        .restarting => "R",
    };
}

fn formatTimeAlloc(allocator: std.mem.Allocator, timestamp_ms: i64) ![]const u8 {
    const total_seconds: i64 = @mod(@divFloor(timestamp_ms, 1000), 24 * 60 * 60);
    const hour = @divFloor(total_seconds, 3600);
    const minute = @divFloor(@mod(total_seconds, 3600), 60);
    const second = @mod(total_seconds, 60);
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u8, @intCast(hour)),
        @as(u8, @intCast(minute)),
        @as(u8, @intCast(second)),
    });
}

test "ui_snapshot_formats_process_row" {
    const row = try formatProcessRow(std.testing.allocator, .{
        .selected = true,
        .status = .running,
        .critical = true,
        .name = "api",
        .pid = 123,
        .restart_count = 2,
        .last_result = "exit=0",
    });
    defer std.testing.allocator.free(row);

    try std.testing.expectEqualStrings("> *! api          running    pid=123 r=2 exit=0", row);
}

test "ui_snapshot_formats_log_prefix" {
    var text = [_]u8{ 'w', 'a', 'r', 'n' };
    const prefix = try formatLogPrefix(std.testing.allocator, .{
        .timestamp_ms = ((60 * 60) + (2 * 60) + 3) * 1000,
        .process_id = 1,
        .process_name = "api",
        .stream = .stderr,
        .text = text[0..],
    });
    defer std.testing.allocator.free(prefix);

    try std.testing.expectEqualStrings("01:02:03 [api:stderr] ", prefix);
}
