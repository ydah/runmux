const std = @import("std");

pub fn sanitize(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte == 0x1b) {
            index = skipEscape(input, index + 1);
            continue;
        }
        if (byte == '\t') {
            try output.appendSlice(allocator, "    ");
            index += 1;
            continue;
        }
        if ((byte < 0x20 and byte != '\n') or byte == 0x7f) {
            index += 1;
            continue;
        }
        try output.append(allocator, byte);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn skipEscape(input: []const u8, start: usize) usize {
    if (start >= input.len) return start;
    const introducer = input[start];
    var index = start + 1;

    switch (introducer) {
        '[' => {
            while (index < input.len) : (index += 1) {
                const byte = input[index];
                if (byte >= 0x40 and byte <= 0x7e) return index + 1;
            }
            return index;
        },
        ']', 'P', '^', '_' => {
            while (index < input.len) : (index += 1) {
                if (input[index] == 0x07) return index + 1;
                if (input[index] == 0x1b and index + 1 < input.len and input[index + 1] == '\\') {
                    return index + 2;
                }
            }
            return index;
        },
        else => return index,
    }
}

test "ansi_sanitize_removes_csi" {
    const clean = try sanitize(std.testing.allocator, "a\x1b[31mred\x1b[0m");
    defer std.testing.allocator.free(clean);
    try std.testing.expectEqualStrings("ared", clean);
}

test "ansi_sanitize_removes_osc" {
    const clean = try sanitize(std.testing.allocator, "a\x1b]0;title\x07b");
    defer std.testing.allocator.free(clean);
    try std.testing.expectEqualStrings("ab", clean);
}
