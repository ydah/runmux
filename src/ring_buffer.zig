const std = @import("std");

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const DeinitItemFn = *const fn (std.mem.Allocator, *T) void;

        allocator: std.mem.Allocator,
        items: []T,
        start: usize = 0,
        count: usize = 0,
        deinit_item: ?DeinitItemFn = null,

        pub fn init(
            allocator: std.mem.Allocator,
            item_capacity: usize,
            deinit_item: ?DeinitItemFn,
        ) !Self {
            if (item_capacity == 0) return error.InvalidCapacity;
            return .{
                .allocator = allocator,
                .items = try allocator.alloc(T, item_capacity),
                .deinit_item = deinit_item,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.deinit_item) |deinit_item| {
                var i: usize = 0;
                while (i < self.count) : (i += 1) {
                    const index = (self.start + i) % self.items.len;
                    deinit_item(self.allocator, &self.items[index]);
                }
            }
            self.allocator.free(self.items);
            self.* = undefined;
        }

        pub fn push(self: *Self, item: T) void {
            if (self.count < self.items.len) {
                const index = (self.start + self.count) % self.items.len;
                self.items[index] = item;
                self.count += 1;
                return;
            }

            if (self.deinit_item) |deinit_item| {
                deinit_item(self.allocator, &self.items[self.start]);
            }
            self.items[self.start] = item;
            self.start = (self.start + 1) % self.items.len;
        }

        pub fn len(self: Self) usize {
            return self.count;
        }

        pub fn capacity(self: Self) usize {
            return self.items.len;
        }

        pub fn at(self: Self, index: usize) ?*const T {
            if (index >= self.count) return null;
            return &self.items[(self.start + index) % self.items.len];
        }

        pub fn snapshot(self: Self, allocator: std.mem.Allocator) ![]T {
            const result = try allocator.alloc(T, self.count);
            for (result, 0..) |*item, index| {
                item.* = self.at(index).?.*;
            }
            return result;
        }
    };
}

fn freeString(allocator: std.mem.Allocator, item: *[]u8) void {
    allocator.free(item.*);
}

test "ring_buffer_keeps_last_n_items" {
    var rb = try RingBuffer(u32).init(std.testing.allocator, 3, null);
    defer rb.deinit();

    rb.push(1);
    rb.push(2);
    rb.push(3);
    rb.push(4);

    try std.testing.expectEqual(@as(usize, 3), rb.len());
    try std.testing.expectEqual(@as(u32, 2), rb.at(0).?.*);
    try std.testing.expectEqual(@as(u32, 3), rb.at(1).?.*);
    try std.testing.expectEqual(@as(u32, 4), rb.at(2).?.*);
}

test "ring_buffer_frees_evicted_items" {
    var rb = try RingBuffer([]u8).init(std.testing.allocator, 1, freeString);
    defer rb.deinit();

    rb.push(try std.testing.allocator.dupe(u8, "first"));
    rb.push(try std.testing.allocator.dupe(u8, "second"));
    try std.testing.expectEqualStrings("second", rb.at(0).?.*);
}
