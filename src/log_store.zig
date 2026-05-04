const std = @import("std");
const ring = @import("ring_buffer.zig");

pub const Stream = enum {
    stdout,
    stderr,
    system,
};

pub const LogLine = struct {
    timestamp_ms: i64,
    process_id: u32,
    process_name: []const u8,
    stream: Stream,
    text: []u8,
};

pub const LogStore = struct {
    allocator: std.mem.Allocator,
    lines: ring.RingBuffer(LogLine),

    pub fn init(allocator: std.mem.Allocator, max_lines: usize) !LogStore {
        return .{
            .allocator = allocator,
            .lines = try ring.RingBuffer(LogLine).init(allocator, max_lines, freeLogLine),
        };
    }

    pub fn deinit(self: *LogStore) void {
        self.lines.deinit();
        self.* = undefined;
    }

    pub fn append(
        self: *LogStore,
        timestamp_ms: i64,
        process_id: u32,
        process_name: []const u8,
        stream: Stream,
        text: []const u8,
    ) !void {
        self.lines.push(.{
            .timestamp_ms = timestamp_ms,
            .process_id = process_id,
            .process_name = process_name,
            .stream = stream,
            .text = try self.allocator.dupe(u8, text),
        });
    }

    pub fn snapshot(self: *const LogStore, allocator: std.mem.Allocator) ![]LogLine {
        return self.lines.snapshot(allocator);
    }
};

fn freeLogLine(allocator: std.mem.Allocator, line: *LogLine) void {
    allocator.free(line.text);
}
