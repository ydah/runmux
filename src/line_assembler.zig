const std = @import("std");

pub const LineAssembler = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,
    max_pending: usize,
    previous_was_cr: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_pending: usize) LineAssembler {
        return .{
            .allocator = allocator,
            .max_pending = max_pending,
        };
    }

    pub fn deinit(self: *LineAssembler) void {
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *LineAssembler, bytes: []const u8, lines: *std.ArrayList([]u8)) !void {
        for (bytes) |byte| {
            if (byte == '\n') {
                if (self.previous_was_cr) {
                    self.previous_was_cr = false;
                    continue;
                }
                try self.emit(lines);
                continue;
            }
            if (byte == '\r') {
                try self.emit(lines);
                self.previous_was_cr = true;
                continue;
            }

            self.previous_was_cr = false;
            try self.pending.append(self.allocator, byte);
            if (self.pending.items.len >= self.max_pending) {
                try self.emit(lines);
            }
        }
    }

    pub fn flush(self: *LineAssembler, lines: *std.ArrayList([]u8)) !void {
        if (self.pending.items.len > 0) {
            try self.emit(lines);
        }
        self.previous_was_cr = false;
    }

    fn emit(self: *LineAssembler, lines: *std.ArrayList([]u8)) !void {
        const line = try self.allocator.dupe(u8, self.pending.items);
        errdefer self.allocator.free(line);
        try lines.append(self.allocator, line);
        self.pending.clearRetainingCapacity();
    }
};

fn freeLines(allocator: std.mem.Allocator, lines: []const []u8) void {
    for (lines) |line| allocator.free(line);
}

test "line_assembler_splits_lf" {
    var assembler = LineAssembler.init(std.testing.allocator, 1024);
    defer assembler.deinit();
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        freeLines(std.testing.allocator, lines.items);
        lines.deinit(std.testing.allocator);
    }

    try assembler.push("a\nb\n", &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("a", lines.items[0]);
    try std.testing.expectEqualStrings("b", lines.items[1]);
}

test "line_assembler_handles_crlf" {
    var assembler = LineAssembler.init(std.testing.allocator, 1024);
    defer assembler.deinit();
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        freeLines(std.testing.allocator, lines.items);
        lines.deinit(std.testing.allocator);
    }

    try assembler.push("a\r\nb\r\n", &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("a", lines.items[0]);
    try std.testing.expectEqualStrings("b", lines.items[1]);
}

test "line_assembler_keeps_partial_line" {
    var assembler = LineAssembler.init(std.testing.allocator, 1024);
    defer assembler.deinit();
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        freeLines(std.testing.allocator, lines.items);
        lines.deinit(std.testing.allocator);
    }

    try assembler.push("partial", &lines);
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
    try assembler.flush(&lines);
    try std.testing.expectEqualStrings("partial", lines.items[0]);
}

test "line_assembler_flushes_overlong_line" {
    var assembler = LineAssembler.init(std.testing.allocator, 4);
    defer assembler.deinit();
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        freeLines(std.testing.allocator, lines.items);
        lines.deinit(std.testing.allocator);
    }

    try assembler.push("abcdef", &lines);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("abcd", lines.items[0]);
    try assembler.flush(&lines);
    try std.testing.expectEqualStrings("ef", lines.items[1]);
}
