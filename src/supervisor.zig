const std = @import("std");
const ansi = @import("ansi_sanitize.zig");
const config = @import("config.zig");
const event_queue = @import("event_queue.zig");
const line_assembler = @import("line_assembler.zig");
const log_store = @import("log_store.zig");
const process_runner = @import("process_runner.zig");

pub const ProcessStatus = enum {
    pending,
    starting,
    running,
    stopping,
    exited,
    failed,
    restarting,
    disabled,
};

pub const LogMode = enum {
    selected,
    all,
};

pub const RuntimeProcess = struct {
    id: u32,
    spec: *const config.ProcessSpec,
    status: ProcessStatus,
    pid: ?u64 = null,
    restart_count: u32 = 0,
    last_exit_code: ?i32 = null,
    last_signal: ?u32 = null,
    last_error: ?[]u8 = null,
    restart_due_ms: ?i64 = null,
    stop_kill_due_ms: ?i64 = null,
    kill_sent: bool = false,
    stop_requested: bool = false,
    pending_manual_restart: bool = false,
    stdout_assembler: line_assembler.LineAssembler,
    stderr_assembler: line_assembler.LineAssembler,
    logs: log_store.LogStore,
    runner: process_runner.ProcessRunner,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_env: *const std.process.Environ.Map,
    profile: *const config.ResolvedProfile,
    queue: *event_queue.EventQueue,
    processes: []RuntimeProcess,
    global_logs: log_store.LogStore,
    selected_index: usize = 0,
    log_mode: LogMode = .selected,
    paused: bool = false,
    paused_log_end: ?usize = null,
    show_help: bool = false,
    should_quit: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent_env: *const std.process.Environ.Map,
        profile: *const config.ResolvedProfile,
    ) !Supervisor {
        const queue = try allocator.create(event_queue.EventQueue);
        queue.* = event_queue.EventQueue.init(allocator, io);
        errdefer {
            queue.deinit();
            allocator.destroy(queue);
        }

        var processes = try allocator.alloc(RuntimeProcess, profile.processes.len);
        errdefer allocator.free(processes);

        for (profile.processes, 0..) |*spec, index| {
            const id: u32 = @intCast(index);
            processes[index] = .{
                .id = id,
                .spec = spec,
                .status = if (spec.autostart) .pending else .disabled,
                .stdout_assembler = line_assembler.LineAssembler.init(allocator, 16 * 1024),
                .stderr_assembler = line_assembler.LineAssembler.init(allocator, 16 * 1024),
                .logs = try log_store.LogStore.init(allocator, @intCast(spec.log.max_lines)),
                .runner = process_runner.ProcessRunner.init(allocator, id, queue),
            };
        }

        return .{
            .allocator = allocator,
            .io = io,
            .parent_env = parent_env,
            .profile = profile,
            .queue = queue,
            .processes = processes,
            .global_logs = try log_store.LogStore.init(allocator, 4000),
        };
    }

    pub fn deinit(self: *Supervisor) void {
        for (self.processes) |*process| {
            process.runner.kill();
            process.runner.join(self.io);
            process.stdout_assembler.deinit();
            process.stderr_assembler.deinit();
            process.logs.deinit();
            if (process.last_error) |message| self.allocator.free(message);
        }
        self.allocator.free(self.processes);
        self.global_logs.deinit();
        self.queue.deinit();
        self.allocator.destroy(self.queue);
        self.* = undefined;
    }

    pub fn startAutostart(self: *Supervisor) void {
        for (self.processes) |*process| {
            if (process.spec.autostart) self.startProcess(process);
        }
    }

    pub fn drainEvents(self: *Supervisor) !void {
        const events = try self.queue.drain(self.allocator);
        defer event_queue.EventQueue.freeDrained(self.allocator, events);

        for (events) |*event| {
            defer event_queue.freeEvent(self.allocator, event);
            switch (event.*) {
                .process_output => |output| try self.handleOutput(output),
                .process_exited => |exited| self.handleExited(exited),
                .process_error => |process_error| try self.handleError(process_error),
            }
        }
    }

    pub fn tick(self: *Supervisor) void {
        const now = nowMs(self.io);
        for (self.processes) |*process| {
            if (process.status == .restarting) {
                if (process.restart_due_ms) |due| {
                    if (now >= due) {
                        process.restart_due_ms = null;
                        self.startProcess(process);
                    }
                }
            }
            if (process.status == .stopping and !process.kill_sent) {
                if (process.stop_kill_due_ms) |due| {
                    if (now >= due) {
                        process.kill_sent = true;
                        process.runner.kill();
                        self.appendSystem(process, "stop timeout reached; sent kill", .{}) catch {};
                    }
                }
            }
        }
    }

    pub fn selectNext(self: *Supervisor) void {
        if (self.processes.len == 0) return;
        self.selected_index = (self.selected_index + 1) % self.processes.len;
        self.refreshPausedLogEnd();
    }

    pub fn selectPrev(self: *Supervisor) void {
        if (self.processes.len == 0) return;
        self.selected_index = if (self.selected_index == 0) self.processes.len - 1 else self.selected_index - 1;
        self.refreshPausedLogEnd();
    }

    pub fn toggleSelected(self: *Supervisor) void {
        const process = self.selectedProcess() orelse return;
        switch (process.status) {
            .running, .starting, .restarting => self.stopProcess(process),
            .stopping => {},
            else => self.startProcess(process),
        }
    }

    pub fn restartSelected(self: *Supervisor) void {
        const process = self.selectedProcess() orelse return;
        switch (process.status) {
            .running, .starting, .restarting => {
                process.pending_manual_restart = true;
                self.stopProcess(process);
            },
            .stopping => process.pending_manual_restart = true,
            else => self.startProcess(process),
        }
    }

    pub fn startAll(self: *Supervisor) void {
        for (self.processes) |*process| self.startProcess(process);
    }

    pub fn stopAll(self: *Supervisor) void {
        for (self.processes) |*process| self.stopProcess(process);
    }

    pub fn toggleLogMode(self: *Supervisor) void {
        self.log_mode = switch (self.log_mode) {
            .selected => .all,
            .all => .selected,
        };
        self.refreshPausedLogEnd();
    }

    pub fn togglePause(self: *Supervisor) void {
        self.paused = !self.paused;
        self.paused_log_end = if (self.paused) self.currentLogCount() else null;
    }

    pub fn selectedProcess(self: *Supervisor) ?*RuntimeProcess {
        if (self.processes.len == 0) return null;
        return &self.processes[self.selected_index];
    }

    pub fn runningCount(self: *const Supervisor) usize {
        var count: usize = 0;
        for (self.processes) |process| {
            if (process.status == .running or process.status == .starting or process.status == .stopping) {
                count += 1;
            }
        }
        return count;
    }

    pub fn currentLogCount(self: *const Supervisor) usize {
        return switch (self.log_mode) {
            .selected => if (self.processes.len == 0) 0 else self.processes[self.selected_index].logs.len(),
            .all => self.global_logs.len(),
        };
    }

    pub fn shutdown(self: *Supervisor) void {
        self.stopAll();
        const deadline = nowMs(self.io) + 2000;
        while (nowMs(self.io) < deadline) {
            self.drainEvents() catch {};
            if (!self.hasActiveProcess()) break;
            std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch {};
        }
        for (self.processes) |*process| process.runner.kill();
        for (self.processes) |*process| process.runner.join(self.io);
    }

    pub fn hasActiveProcess(self: *const Supervisor) bool {
        for (self.processes) |process| {
            switch (process.status) {
                .running, .starting, .stopping, .restarting => return true,
                else => {},
            }
        }
        return false;
    }

    pub fn hasFailedProcess(self: *const Supervisor) bool {
        for (self.processes) |process| {
            if (process.status == .failed) return true;
        }
        return false;
    }

    fn startProcess(self: *Supervisor, process: *RuntimeProcess) void {
        switch (process.status) {
            .running, .starting, .stopping => return,
            else => {},
        }

        process.status = .starting;
        process.stop_requested = false;
        process.pending_manual_restart = false;
        process.stop_kill_due_ms = null;
        process.kill_sent = false;
        process.last_exit_code = null;
        process.last_signal = null;
        self.setLastError(process, null);

        const pid = process.runner.start(self.io, self.parent_env, process.spec) catch |err| {
            process.status = .failed;
            self.setLastError(process, @errorName(err));
            self.appendSystem(process, "spawn failed: {s}", .{@errorName(err)}) catch {};
            self.scheduleRestart(process, true);
            return;
        };

        process.pid = @import("platform.zig").pidToU64(pid);
        process.status = .running;
        self.appendSystem(process, "started pid={d}", .{process.pid.?}) catch {};
    }

    fn stopProcess(self: *Supervisor, process: *RuntimeProcess) void {
        switch (process.status) {
            .running, .starting => {
                process.stop_requested = true;
                process.status = .stopping;
                process.stop_kill_due_ms = nowMs(self.io) + 2000;
                process.kill_sent = false;
                process.runner.stop();
                self.appendSystem(process, "stopping", .{}) catch {};
            },
            .restarting => {
                process.stop_requested = false;
                process.pending_manual_restart = false;
                process.restart_due_ms = null;
                process.status = .exited;
                self.appendSystem(process, "restart canceled", .{}) catch {};
            },
            else => {},
        }
    }

    fn handleOutput(self: *Supervisor, output: event_queue.ProcessOutput) !void {
        const process = self.processById(output.process_id) orelse return;
        var lines: std.ArrayList([]u8) = .empty;
        defer {
            for (lines.items) |line| self.allocator.free(line);
            lines.deinit(self.allocator);
        }

        switch (output.stream) {
            .stdout => try process.stdout_assembler.push(output.bytes, &lines),
            .stderr => try process.stderr_assembler.push(output.bytes, &lines),
            .system => unreachable,
        }

        for (lines.items) |line| {
            const display = if (process.spec.log.strip_ansi)
                try ansi.sanitize(self.allocator, line)
            else
                try self.allocator.dupe(u8, line);
            defer self.allocator.free(display);
            try self.appendLog(process, output.stream, display);
        }
    }

    fn handleExited(self: *Supervisor, exited: event_queue.ProcessExited) void {
        const process = self.processById(exited.process_id) orelse return;
        process.runner.join(self.io);
        process.pid = null;
        process.restart_due_ms = null;
        process.stop_kill_due_ms = null;
        process.kill_sent = false;

        const failed = self.applyTerm(process, exited.term);
        const term_text = termTextAlloc(self.allocator, exited.term) catch null;
        if (term_text) |text| {
            defer self.allocator.free(text);
            self.appendSystem(process, "exited {s}", .{text}) catch {};
        } else {
            self.appendSystem(process, "exited unknown", .{}) catch {};
        }

        if (process.pending_manual_restart) {
            process.pending_manual_restart = false;
            process.stop_requested = false;
            process.status = .exited;
            self.startProcess(process);
            return;
        }

        if (process.stop_requested) {
            process.status = .exited;
            process.stop_requested = false;
            return;
        }

        process.status = if (failed) .failed else .exited;
        self.scheduleRestart(process, failed);
    }

    fn handleError(self: *Supervisor, process_error: event_queue.ProcessError) !void {
        const process = self.processById(process_error.process_id) orelse return;
        self.setLastError(process, process_error.message);
        try self.appendLog(process, .system, process_error.message);
    }

    fn scheduleRestart(self: *Supervisor, process: *RuntimeProcess, failed: bool) void {
        const policy = process.spec.restart.policy;
        const should_restart = switch (policy) {
            .never => false,
            .on_failure => failed,
            .always => true,
        };
        if (!should_restart) return;

        if (process.restart_count >= process.spec.restart.max_restarts) {
            process.status = .failed;
            self.appendSystem(process, "restart limit reached", .{}) catch {};
            return;
        }

        process.restart_count += 1;
        process.status = .restarting;
        process.restart_due_ms = nowMs(self.io) + @as(i64, @intCast(process.spec.restart.delay_ms));
        self.appendSystem(process, "restarting in {d}ms", .{process.spec.restart.delay_ms}) catch {};
    }

    fn appendSystem(self: *Supervisor, process: *RuntimeProcess, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.appendLog(process, .system, text);
    }

    fn appendLog(self: *Supervisor, process: *RuntimeProcess, stream: log_store.Stream, text: []const u8) !void {
        const timestamp = nowMs(self.io);
        try process.logs.append(timestamp, process.id, process.spec.name, stream, text);
        try self.global_logs.append(timestamp, process.id, process.spec.name, stream, text);
    }

    fn processById(self: *Supervisor, id: u32) ?*RuntimeProcess {
        if (@as(usize, @intCast(id)) >= self.processes.len) return null;
        return &self.processes[@intCast(id)];
    }

    fn refreshPausedLogEnd(self: *Supervisor) void {
        if (self.paused) self.paused_log_end = self.currentLogCount();
    }

    fn applyTerm(self: *Supervisor, process: *RuntimeProcess, term: event_queue.TermInfo) bool {
        _ = self;
        process.last_exit_code = null;
        process.last_signal = null;
        return switch (term) {
            .exited => |code| blk: {
                process.last_exit_code = code;
                break :blk code != 0;
            },
            .signal => |signal| blk: {
                process.last_signal = signal;
                break :blk true;
            },
            .stopped => |signal| blk: {
                process.last_signal = signal;
                break :blk true;
            },
            .unknown => true,
        };
    }

    fn setLastError(self: *Supervisor, process: *RuntimeProcess, message: ?[]const u8) void {
        if (process.last_error) |old| self.allocator.free(old);
        process.last_error = if (message) |text| self.allocator.dupe(u8, text) catch null else null;
    }
};

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn termTextAlloc(allocator: std.mem.Allocator, term: event_queue.TermInfo) ![]u8 {
    return switch (term) {
        .exited => |code| std.fmt.allocPrint(allocator, "exit={d}", .{code}),
        .signal => |signal| std.fmt.allocPrint(allocator, "signal={d}", .{signal}),
        .stopped => |signal| std.fmt.allocPrint(allocator, "stopped={d}", .{signal}),
        .unknown => |code| std.fmt.allocPrint(allocator, "unknown={d}", .{code}),
    };
}
