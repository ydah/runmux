const std = @import("std");
const log_store = @import("log_store.zig");

pub const TermInfo = union(enum) {
    exited: u8,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub const ProcessOutput = struct {
    process_id: u32,
    stream: log_store.Stream,
    bytes: []u8,
};

pub const ProcessExited = struct {
    process_id: u32,
    term: TermInfo,
};

pub const ProcessError = struct {
    process_id: u32,
    message: []u8,
};

pub const AppEvent = union(enum) {
    process_output: ProcessOutput,
    process_exited: ProcessExited,
    process_error: ProcessError,
};

pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(AppEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) EventQueue {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *EventQueue) void {
        self.mutex.lockUncancelable(self.io);
        for (self.events.items) |*event| freeEvent(self.allocator, event);
        self.events.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    pub fn push(self: *EventQueue, event: AppEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.events.append(self.allocator, event);
    }

    pub fn drain(self: *EventQueue, allocator: std.mem.Allocator) ![]AppEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const result = try allocator.dupe(AppEvent, self.events.items);
        self.events.clearRetainingCapacity();
        return result;
    }

    pub fn freeDrained(allocator: std.mem.Allocator, events: []AppEvent) void {
        allocator.free(events);
    }
};

pub fn freeEvent(allocator: std.mem.Allocator, event: *AppEvent) void {
    switch (event.*) {
        .process_output => |output| allocator.free(output.bytes),
        .process_error => |process_error| allocator.free(process_error.message),
        .process_exited => {},
    }
}

pub fn termFromChild(term: std.process.Child.Term) TermInfo {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |signal| .{ .signal = @intFromEnum(signal) },
        .stopped => |signal| .{ .stopped = @intFromEnum(signal) },
        .unknown => |code| .{ .unknown = code },
    };
}
