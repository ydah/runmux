const std = @import("std");
const config = @import("config.zig");
const event_queue = @import("event_queue.zig");
const log_store = @import("log_store.zig");
const platform = @import("platform.zig");

pub const ProcessRunner = struct {
    allocator: std.mem.Allocator,
    process_id: u32,
    queue: *event_queue.EventQueue,
    child: ?*std.process.Child = null,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    process_group: bool = false,

    pub fn init(allocator: std.mem.Allocator, process_id: u32, queue: *event_queue.EventQueue) ProcessRunner {
        return .{
            .allocator = allocator,
            .process_id = process_id,
            .queue = queue,
        };
    }

    pub fn start(
        self: *ProcessRunner,
        io: std.Io,
        parent_env: *const std.process.Environ.Map,
        spec: *const config.ProcessSpec,
    ) !std.process.Child.Id {
        if (self.child != null) return error.AlreadyRunning;

        var env = try parent_env.clone(self.allocator);
        defer env.deinit();
        for (spec.env) |entry| {
            try env.put(entry.key, entry.value);
        }

        const argv = if (spec.cmd) |cmd|
            if (spec.shell)
                try platform.shellArgv(self.allocator, cmd, parent_env.get("SHELL") orelse "/bin/sh")
            else
                try platform.directArgv(self.allocator, cmd)
        else
            spec.argv;
        defer if (spec.cmd != null) self.allocator.free(argv);

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = spec.cwd },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = platform.childProcessGroupId(),
        });
        errdefer child.kill(io);

        const stdout_file = child.stdout.?;
        const stderr_file = child.stderr.?;
        child.stdout = null;
        child.stderr = null;

        const pid = child.id.?;
        const child_ptr = try self.allocator.create(std.process.Child);
        child_ptr.* = child;
        errdefer self.allocator.destroy(child_ptr);

        const stdout_thread = std.Thread.spawn(.{}, readerThread, .{ReaderContext{
            .allocator = self.allocator,
            .queue = self.queue,
            .process_id = self.process_id,
            .stream = .stdout,
            .file = stdout_file,
            .io = io,
        }}) catch |err| {
            stdout_file.close(io);
            stderr_file.close(io);
            child_ptr.kill(io);
            return err;
        };
        errdefer stdout_thread.join();

        const stderr_thread = std.Thread.spawn(.{}, readerThread, .{ReaderContext{
            .allocator = self.allocator,
            .queue = self.queue,
            .process_id = self.process_id,
            .stream = .stderr,
            .file = stderr_file,
            .io = io,
        }}) catch |err| {
            platform.sendTerm(pid, platform.childProcessGroupId() != null);
            stderr_file.close(io);
            child_ptr.kill(io);
            return err;
        };
        errdefer stderr_thread.join();

        const wait_thread = std.Thread.spawn(.{}, waitThread, .{WaitContext{
            .allocator = self.allocator,
            .queue = self.queue,
            .process_id = self.process_id,
            .child = child_ptr,
            .io = io,
        }}) catch |err| {
            platform.sendTerm(pid, platform.childProcessGroupId() != null);
            child_ptr.kill(io);
            return err;
        };

        self.child = child_ptr;
        self.stdout_thread = stdout_thread;
        self.stderr_thread = stderr_thread;
        self.wait_thread = wait_thread;
        self.process_group = platform.childProcessGroupId() != null;

        return pid;
    }

    pub fn stop(self: *ProcessRunner) void {
        const child = self.child orelse return;
        const pid = child.id orelse return;
        platform.sendTerm(pid, self.process_group);
    }

    pub fn kill(self: *ProcessRunner) void {
        const child = self.child orelse return;
        const pid = child.id orelse return;
        platform.sendKill(pid, self.process_group);
    }

    pub fn join(self: *ProcessRunner, io: std.Io) void {
        _ = io;
        if (self.stdout_thread) |thread| thread.join();
        if (self.stderr_thread) |thread| thread.join();
        if (self.wait_thread) |thread| thread.join();
        if (self.child) |child| self.allocator.destroy(child);

        self.child = null;
        self.stdout_thread = null;
        self.stderr_thread = null;
        self.wait_thread = null;
        self.process_group = false;
    }
};

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    queue: *event_queue.EventQueue,
    process_id: u32,
    stream: log_store.Stream,
    file: std.Io.File,
    io: std.Io,
};

fn readerThread(context: ReaderContext) void {
    var file = context.file;
    defer file.close(context.io);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(file.handle, buffer[0..]) catch |err| {
            postError(context.allocator, context.queue, context.process_id, "read failed: {s}", .{@errorName(err)});
            return;
        };
        if (n == 0) return;

        const bytes = context.allocator.dupe(u8, buffer[0..n]) catch {
            postError(context.allocator, context.queue, context.process_id, "read failed: out of memory", .{});
            return;
        };
        context.queue.push(.{ .process_output = .{
            .process_id = context.process_id,
            .stream = context.stream,
            .bytes = bytes,
        } }) catch {
            context.allocator.free(bytes);
            return;
        };
    }
}

const WaitContext = struct {
    allocator: std.mem.Allocator,
    queue: *event_queue.EventQueue,
    process_id: u32,
    child: *std.process.Child,
    io: std.Io,
};

fn waitThread(context: WaitContext) void {
    const term = context.child.wait(context.io) catch |err| {
        postError(context.allocator, context.queue, context.process_id, "wait failed: {s}", .{@errorName(err)});
        return;
    };

    context.queue.push(.{ .process_exited = .{
        .process_id = context.process_id,
        .term = event_queue.termFromChild(term),
    } }) catch {};
}

fn postError(
    allocator: std.mem.Allocator,
    queue: *event_queue.EventQueue,
    process_id: u32,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;
    queue.push(.{ .process_error = .{
        .process_id = process_id,
        .message = message,
    } }) catch allocator.free(message);
}
