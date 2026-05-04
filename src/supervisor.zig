const std = @import("std");
const ansi = @import("ansi_sanitize.zig");
const config = @import("config.zig");
const event_queue = @import("event_queue.zig");
const line_assembler = @import("line_assembler.zig");
const log_store = @import("log_store.zig");
const platform = @import("platform.zig");
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

pub const InputMode = enum {
    none,
    search,
    stdin,
};

pub const HealthStatus = enum {
    none,
    checking,
    healthy,
    unhealthy,
};

pub const Options = struct {
    log_dir: ?[]const u8 = null,
    exit_on_critical_failure: bool = false,
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
    start_when_dependencies_ready: bool = false,
    dependency_wait_logged: bool = false,
    health_status: HealthStatus = .none,
    health_attempts: u32 = 0,
    next_health_check_ms: ?i64 = null,
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
    options: Options,
    processes: []RuntimeProcess,
    global_logs: log_store.LogStore,
    log_files: []?std.Io.File,
    selected_index: usize = 0,
    log_mode: LogMode = .selected,
    paused: bool = false,
    paused_log_end: ?usize = null,
    input_mode: InputMode = .none,
    search_input: std.ArrayList(u8) = .empty,
    filter_query: ?[]u8 = null,
    filter_stream: ?log_store.Stream = null,
    filter_process_id: ?u32 = null,
    show_help: bool = false,
    should_quit: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent_env: *const std.process.Environ.Map,
        profile: *const config.ResolvedProfile,
        options: Options,
    ) !Supervisor {
        const queue = try allocator.create(event_queue.EventQueue);
        queue.* = event_queue.EventQueue.init(allocator, io);
        errdefer {
            queue.deinit();
            allocator.destroy(queue);
        }

        var processes = try allocator.alloc(RuntimeProcess, profile.processes.len);
        var initialized_processes: usize = 0;
        errdefer {
            for (processes[0..initialized_processes]) |*process| {
                process.stdout_assembler.deinit();
                process.stderr_assembler.deinit();
                process.logs.deinit();
            }
            allocator.free(processes);
        }

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
            initialized_processes += 1;
        }

        const log_files = try openLogFiles(allocator, io, profile, options.log_dir);
        errdefer closeLogFiles(io, allocator, log_files);
        var global_logs = try log_store.LogStore.init(allocator, 4000);
        errdefer global_logs.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .parent_env = parent_env,
            .profile = profile,
            .queue = queue,
            .options = options,
            .processes = processes,
            .global_logs = global_logs,
            .log_files = log_files,
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
        closeLogFiles(self.io, self.allocator, self.log_files);
        self.allocator.free(self.processes);
        self.global_logs.deinit();
        self.search_input.deinit(self.allocator);
        if (self.filter_query) |query| self.allocator.free(query);
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
            if (process.status == .pending and process.start_when_dependencies_ready and self.dependenciesReady(process)) {
                self.startProcess(process);
            }
            if (process.status == .running and process.health_status == .checking) {
                if (process.next_health_check_ms) |due| {
                    if (now >= due) self.runHealthCheck(process, now);
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

    pub fn beginSearch(self: *Supervisor) void {
        self.input_mode = .search;
        self.search_input.clearRetainingCapacity();
        if (self.filter_query) |query| {
            self.search_input.appendSlice(self.allocator, query) catch {};
        }
    }

    pub fn beginStdinInput(self: *Supervisor) void {
        self.input_mode = .stdin;
        self.search_input.clearRetainingCapacity();
    }

    pub fn cancelInput(self: *Supervisor) void {
        self.input_mode = .none;
        self.search_input.clearRetainingCapacity();
    }

    pub fn appendInputText(self: *Supervisor, text: []const u8) void {
        if (self.input_mode == .none) return;
        self.search_input.appendSlice(self.allocator, text) catch {};
    }

    pub fn deleteInputByte(self: *Supervisor) void {
        if (self.search_input.items.len == 0) return;
        _ = self.search_input.pop();
    }

    pub fn applySearch(self: *Supervisor) void {
        if (self.filter_query) |query| self.allocator.free(query);
        self.filter_query = if (self.search_input.items.len == 0)
            null
        else
            self.allocator.dupe(u8, self.search_input.items) catch null;
        self.cancelInput();
        self.refreshPausedLogEnd();
    }

    pub fn sendStdinInput(self: *Supervisor) void {
        const process = self.selectedProcess() orelse {
            self.cancelInput();
            return;
        };
        if (process.status != .running) {
            self.appendSystem(process, "stdin ignored: process is not running", .{}) catch {};
            self.cancelInput();
            return;
        }

        const line = std.fmt.allocPrint(self.allocator, "{s}\n", .{self.search_input.items}) catch {
            self.cancelInput();
            return;
        };
        defer self.allocator.free(line);
        process.runner.writeStdin(self.io, line) catch |err| {
            self.setLastError(process, @errorName(err));
            self.appendSystem(process, "stdin failed: {s}", .{@errorName(err)}) catch {};
            self.cancelInput();
            return;
        };
        self.appendSystem(process, "stdin sent", .{}) catch {};
        self.cancelInput();
    }

    pub fn cycleStreamFilter(self: *Supervisor) void {
        self.filter_stream = if (self.filter_stream) |stream| switch (stream) {
            .stdout => .stderr,
            .stderr => .system,
            .system => null,
        } else .stdout;
        self.refreshPausedLogEnd();
    }

    pub fn toggleProcessFilter(self: *Supervisor) void {
        const selected = if (self.selectedProcess()) |process| process.id else return;
        self.filter_process_id = if (self.filter_process_id) |current|
            if (current == selected) null else selected
        else
            selected;
        self.refreshPausedLogEnd();
    }

    pub fn clearFilters(self: *Supervisor) void {
        if (self.filter_query) |query| self.allocator.free(query);
        self.filter_query = null;
        self.filter_stream = null;
        self.filter_process_id = null;
        self.refreshPausedLogEnd();
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
        process.start_when_dependencies_ready = false;
        process.dependency_wait_logged = false;
        process.health_status = .none;
        process.health_attempts = 0;
        process.next_health_check_ms = null;
        process.stop_requested = false;
        process.pending_manual_restart = false;
        process.stop_kill_due_ms = null;
        process.kill_sent = false;
        process.last_exit_code = null;
        process.last_signal = null;
        self.setLastError(process, null);

        if (!self.dependenciesReady(process)) {
            process.status = .pending;
            process.start_when_dependencies_ready = true;
            if (!process.dependency_wait_logged) {
                self.appendSystem(process, "waiting for dependencies", .{}) catch {};
                process.dependency_wait_logged = true;
            }
            return;
        }

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
        if (process.spec.health != null) {
            process.health_status = .checking;
            process.next_health_check_ms = nowMs(self.io);
            self.appendSystem(process, "health checking", .{}) catch {};
        }
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
                process.start_when_dependencies_ready = false;
                process.restart_due_ms = null;
                process.status = .exited;
                self.appendSystem(process, "restart canceled", .{}) catch {};
            },
            .pending => {
                process.start_when_dependencies_ready = false;
                process.status = .exited;
                self.appendSystem(process, "start canceled", .{}) catch {};
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
        if (failed and self.handleCriticalFailure(process)) return;
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
        if (self.log_files.len > process.id) {
            if (self.log_files[process.id]) |file| {
                writeLogFileLine(self.io, file, timestamp, process.spec.name, stream, text) catch |err| {
                    self.setLastError(process, @errorName(err));
                };
            }
        }
    }

    fn processById(self: *Supervisor, id: u32) ?*RuntimeProcess {
        if (@as(usize, @intCast(id)) >= self.processes.len) return null;
        return &self.processes[@intCast(id)];
    }

    fn processByName(self: *Supervisor, name: []const u8) ?*RuntimeProcess {
        for (self.processes) |*process| {
            if (std.mem.eql(u8, process.spec.name, name)) return process;
        }
        return null;
    }

    fn refreshPausedLogEnd(self: *Supervisor) void {
        if (self.paused) self.paused_log_end = self.currentLogCount();
    }

    fn dependenciesReady(self: *Supervisor, process: *const RuntimeProcess) bool {
        for (process.spec.depends_on) |dependency_name| {
            const dependency = self.processByName(dependency_name) orelse return false;
            switch (dependency.status) {
                .running => {
                    if (dependency.spec.health != null and dependency.health_status != .healthy) return false;
                },
                .exited => {
                    if (dependency.last_exit_code == null or dependency.last_exit_code.? != 0) return false;
                },
                else => return false,
            }
        }
        return true;
    }

    fn runHealthCheck(self: *Supervisor, process: *RuntimeProcess, now: i64) void {
        const healthy = self.executeHealthCheck(process) catch |err| blk: {
            self.setLastError(process, @errorName(err));
            break :blk false;
        };
        if (healthy) {
            process.health_status = .healthy;
            process.next_health_check_ms = null;
            self.appendSystem(process, "health ok", .{}) catch {};
            return;
        }

        process.health_attempts += 1;
        const health = process.spec.health.?;
        if (process.health_attempts < health.retries) {
            process.next_health_check_ms = now + @as(i64, @intCast(health.interval_ms));
            self.appendSystem(process, "health check failed; retrying {d}/{d}", .{
                process.health_attempts,
                health.retries,
            }) catch {};
            return;
        }

        process.health_status = .unhealthy;
        process.next_health_check_ms = null;
        self.setLastError(process, "health check failed");
        self.appendSystem(process, "health check failed; stopping", .{}) catch {};
        process.status = .stopping;
        process.stop_kill_due_ms = now + 2000;
        process.kill_sent = false;
        process.runner.stop();
    }

    fn executeHealthCheck(self: *Supervisor, process: *const RuntimeProcess) !bool {
        const health = process.spec.health.?;
        var env = try self.parent_env.clone(self.allocator);
        defer env.deinit();
        for (process.spec.env) |entry| {
            try env.put(entry.key, entry.value);
        }

        const argv = if (health.cmd) |cmd|
            try platform.shellArgv(self.allocator, cmd, self.parent_env.get("SHELL") orelse "/bin/sh")
        else
            health.argv;
        defer if (health.cmd != null) self.allocator.free(argv);

        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = process.spec.cwd },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = platform.childProcessGroupId(),
        });
        const term = try child.wait(self.io);
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    fn handleCriticalFailure(self: *Supervisor, process: *RuntimeProcess) bool {
        if (!self.options.exit_on_critical_failure or !process.spec.critical) return false;
        self.appendSystem(process, "critical process failed; stopping all", .{}) catch {};
        for (self.processes) |*other| {
            if (other.id != process.id) self.stopProcess(other);
        }
        self.should_quit = true;
        return true;
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

fn openLogFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    profile: *const config.ResolvedProfile,
    log_dir: ?[]const u8,
) ![]?std.Io.File {
    const dir_path = log_dir orelse return allocator.alloc(?std.Io.File, 0);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    var files = try allocator.alloc(?std.Io.File, profile.processes.len);
    @memset(files, null);
    errdefer closeLogFiles(io, allocator, files);

    for (profile.processes, 0..) |process, index| {
        const path = try logFilePath(allocator, dir_path, process.name);
        defer allocator.free(path);
        files[index] = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    }
    return files;
}

fn closeLogFiles(io: std.Io, allocator: std.mem.Allocator, files: []?std.Io.File) void {
    for (files) |maybe_file| {
        if (maybe_file) |file| file.close(io);
    }
    allocator.free(files);
}

fn logFilePath(allocator: std.mem.Allocator, dir_path: []const u8, process_name: []const u8) ![]u8 {
    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(allocator);

    try path.appendSlice(allocator, dir_path);
    if (dir_path.len > 0 and dir_path[dir_path.len - 1] != std.fs.path.sep) {
        try path.append(allocator, std.fs.path.sep);
    }
    for (process_name) |byte| {
        const safe = switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => byte,
            else => '_',
        };
        try path.append(allocator, safe);
    }
    try path.appendSlice(allocator, ".log");
    return path.toOwnedSlice(allocator);
}

fn writeLogFileLine(
    io: std.Io,
    file: std.Io.File,
    timestamp_ms: i64,
    process_name: []const u8,
    stream: log_store.Stream,
    text: []const u8,
) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    const time = formatTime(timestamp_ms);
    try writer.interface.print("{s} [{s}:{s}] {s}\n", .{
        &time,
        process_name,
        @tagName(stream),
        text,
    });
    try writer.interface.flush();
}

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
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

fn termTextAlloc(allocator: std.mem.Allocator, term: event_queue.TermInfo) ![]u8 {
    return switch (term) {
        .exited => |code| std.fmt.allocPrint(allocator, "exit={d}", .{code}),
        .signal => |signal| std.fmt.allocPrint(allocator, "signal={d}", .{signal}),
        .stopped => |signal| std.fmt.allocPrint(allocator, "stopped={d}", .{signal}),
        .unknown => |code| std.fmt.allocPrint(allocator, "unknown={d}", .{code}),
    };
}
