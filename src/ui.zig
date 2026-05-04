const std = @import("std");
const vaxis = @import("vaxis");
const config = @import("config.zig");
const log_store = @import("log_store.zig");
const supervisor_mod = @import("supervisor.zig");

const Supervisor = supervisor_mod.Supervisor;

const VaxisEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    profile: *const config.ResolvedProfile,
) !void {
    var supervisor = try Supervisor.init(allocator, io, environ_map, profile);
    defer supervisor.deinit();

    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, allocator, environ_map, .{});
    defer vx.deinit(allocator, tty.writer());

    try vx.enterAltScreen(tty.writer());
    try vx.setBracketedPaste(tty.writer(), false);

    var loop = vaxis.Loop(VaxisEvent).init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();

    const winsize = try tty.getWinsize();
    try vx.resize(allocator, tty.writer(), winsize);
    vx.queueRefresh();
    supervisor.startAutostart();

    while (!supervisor.should_quit) {
        while (try loop.tryEvent()) |event| {
            switch (event) {
                .winsize => |ws| {
                    try vx.resize(allocator, tty.writer(), ws);
                    vx.queueRefresh();
                },
                .key_press => |key| handleKey(&supervisor, key),
            }
        }

        try supervisor.drainEvents();
        supervisor.tick();
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        try render(frame_arena.allocator(), &vx, &supervisor);
        try vx.render(tty.writer());
        try std.Io.sleep(io, .fromMilliseconds(33), .awake);
    }

    supervisor.shutdown();
}

fn handleKey(supervisor: *Supervisor, key: vaxis.Key) void {
    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
        supervisor.should_quit = true;
        return;
    }
    if (key.codepoint == vaxis.Key.down or key.matches('j', .{})) {
        supervisor.selectNext();
        return;
    }
    if (key.codepoint == vaxis.Key.up or key.matches('k', .{})) {
        supervisor.selectPrev();
        return;
    }
    if (key.codepoint == vaxis.Key.enter) {
        supervisor.toggleSelected();
        return;
    }
    if (key.matches('r', .{})) {
        supervisor.restartSelected();
        return;
    }
    if (key.matches('a', .{})) {
        supervisor.startAll();
        return;
    }
    if (key.matches('x', .{})) {
        supervisor.stopAll();
        return;
    }
    if (key.codepoint == vaxis.Key.tab) {
        supervisor.toggleLogMode();
        return;
    }
    if (key.matches('p', .{})) {
        supervisor.togglePause();
        return;
    }
    if (key.matches('?', .{})) {
        supervisor.show_help = !supervisor.show_help;
    }
}

fn render(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, supervisor: *Supervisor) !void {
    const root = vx.window();
    root.clear();
    root.hideCursor();

    if (root.width < 40 or root.height < 8) {
        print(root, 0, 0, "runmux: terminal too small", .{ .fg = .{ .index = 1 }, .bold = true });
        return;
    }

    try renderHeader(root, allocator, supervisor);
    try renderPanes(root, allocator, supervisor);
    renderFooter(root, supervisor);
    if (supervisor.show_help) renderHelp(root);
}

fn renderHeader(root: vaxis.Window, allocator: std.mem.Allocator, supervisor: *Supervisor) !void {
    const selected_name = if (supervisor.selectedProcess()) |process| process.spec.name else "-";
    const text = try std.fmt.allocPrint(allocator, " runmux | profile: {s} | running: {d}/{d} | selected: {s} | logs: {s}{s}", .{
        supervisor.profile.name,
        supervisor.runningCount(),
        supervisor.processes.len,
        selected_name,
        @tagName(supervisor.log_mode),
        if (supervisor.paused) " | paused" else "",
    });
    print(root, 0, 0, text, .{ .fg = .{ .index = 15 }, .bg = .{ .index = 4 }, .bold = true });
}

fn renderPanes(root: vaxis.Window, allocator: std.mem.Allocator, supervisor: *Supervisor) !void {
    const footer_rows: u16 = 2;
    const top: u16 = 2;
    const content_height = root.height - top - footer_rows;
    const process_width: u16 = if (root.width < 90) @max(@as(u16, 28), root.width / 3) else 46;
    const log_x = process_width + 2;
    const log_width = root.width - log_x;
    const process_window = root.child(.{ .x_off = 0, .y_off = 0, .width = process_width, .height = root.height });
    const log_window = root.child(.{ .x_off = @intCast(log_x), .y_off = 0, .width = log_width, .height = root.height });

    print(root, 0, 1, "Processes", .{ .bold = true });
    print(root, log_x, 1, "Logs", .{ .bold = true });

    var row: u16 = top;
    for (supervisor.processes, 0..) |*process, index| {
        if (row >= top + content_height) break;
        const selected = index == supervisor.selected_index;
        const pid_text = if (process.pid) |pid| try std.fmt.allocPrint(allocator, "{d}", .{pid}) else "-";
        const last_text = try lastResultAlloc(allocator, process);
        const line = try std.fmt.allocPrint(allocator, "{s} {s}{s} {s:<12} {s:<10} pid={s} r={d} {s}", .{
            if (selected) ">" else " ",
            statusGlyph(process.status),
            if (process.spec.critical) "!" else " ",
            process.spec.name,
            @tagName(process.status),
            pid_text,
            process.restart_count,
            last_text,
        });
        print(process_window, 0, row, line, if (selected) .{ .reverse = true, .bold = true } else statusStyle(process.status));
        row += 1;
    }

    row = top;
    while (row < top + content_height) : (row += 1) {
        root.writeCell(process_width, row, .{ .char = .{ .grapheme = "|", .width = 1 }, .style = .{ .fg = .{ .index = 8 } } });
    }

    const logs = switch (supervisor.log_mode) {
        .selected => if (supervisor.selectedProcess()) |process| try process.logs.snapshot(allocator) else &.{},
        .all => try supervisor.global_logs.snapshot(allocator),
    };
    defer if (logs.len > 0) allocator.free(logs);

    const visible: usize = content_height;
    const end = if (supervisor.paused_log_end) |paused_end| @min(paused_end, logs.len) else logs.len;
    const start = if (end > visible) end - visible else 0;
    row = top;
    for (logs[start..end]) |line| {
        if (row >= top + content_height) break;
        const time_text = try formatTimeAlloc(allocator, line.timestamp_ms);
        const prefix = try std.fmt.allocPrint(allocator, "{s} [{s}:{s}] ", .{
            time_text,
            line.process_name,
            @tagName(line.stream),
        });
        print(log_window, 0, row, prefix, streamStyle(line.stream, true));
        const prefix_width: u16 = @intCast(@min(prefix.len, @as(usize, log_window.width)));
        if (prefix_width < log_window.width) {
            print(log_window, prefix_width, row, line.text, streamStyle(line.stream, false));
        }
        row += 1;
    }
}

fn renderFooter(root: vaxis.Window, supervisor: *Supervisor) void {
    _ = supervisor;
    const row = root.height - 2;
    print(root, 0, row, " Up/Down j/k select  Enter start/stop  r restart  a start-all  x stop-all  Tab logs", .{
        .fg = .{ .index = 15 },
        .bg = .{ .index = 8 },
    });
    print(root, 0, row + 1, " p pause  ? help  q quit  Ctrl+C quit", .{
        .fg = .{ .index = 15 },
        .bg = .{ .index = 8 },
    });
}

fn renderHelp(root: vaxis.Window) void {
    const width: u16 = @min(root.width - 4, 64);
    const height: u16 = 10;
    const x: i17 = @intCast((root.width - width) / 2);
    const y: i17 = @intCast((root.height - height) / 2);
    const popup = root.child(.{
        .x_off = x,
        .y_off = y,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .glyphs = .single_square, .style = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } } },
    });
    popup.clear();
    const style: vaxis.Style = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } };
    print(popup, 1, 0, "runmux keys", .{ .fg = .{ .index = 14 }, .bg = .{ .index = 0 }, .bold = true });
    print(popup, 1, 2, "j/k or arrows   select process", style);
    print(popup, 1, 3, "Enter           start or stop selected", style);
    print(popup, 1, 4, "r               restart selected", style);
    print(popup, 1, 5, "a / x           start all / stop all", style);
    print(popup, 1, 6, "Tab             selected or all logs", style);
    print(popup, 1, 7, "p               pause or resume log follow", style);
    print(popup, 1, 8, "q or Ctrl+C     quit and stop children", style);
}

fn print(window: vaxis.Window, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= window.height or col >= window.width) return;
    const segments = [_]vaxis.Segment{.{ .text = text, .style = style }};
    _ = window.print(&segments, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
}

fn statusGlyph(status: supervisor_mod.ProcessStatus) []const u8 {
    return switch (status) {
        .pending, .disabled, .exited => "o",
        .starting, .stopping => "~",
        .running => "*",
        .failed => "!",
        .restarting => "R",
    };
}

fn statusStyle(status: supervisor_mod.ProcessStatus) vaxis.Style {
    return switch (status) {
        .running => .{ .fg = .{ .index = 2 }, .bold = true },
        .failed => .{ .fg = .{ .index = 1 }, .bold = true },
        .restarting, .starting, .stopping => .{ .fg = .{ .index = 3 }, .bold = true },
        else => .{ .fg = .{ .index = 8 } },
    };
}

fn streamStyle(stream: log_store.Stream, prefix: bool) vaxis.Style {
    return switch (stream) {
        .stdout => if (prefix) .{ .fg = .{ .index = 6 }, .bold = true } else .{},
        .stderr => .{ .fg = .{ .index = 1 }, .bold = prefix },
        .system => .{ .fg = .{ .index = 3 }, .bold = prefix },
    };
}

fn lastResultAlloc(allocator: std.mem.Allocator, process: *const supervisor_mod.RuntimeProcess) ![]const u8 {
    if (process.last_exit_code) |code| {
        return std.fmt.allocPrint(allocator, "exit={d}", .{code});
    }
    if (process.last_signal) |signal| {
        return std.fmt.allocPrint(allocator, "sig={d}", .{signal});
    }
    if (process.last_error != null) {
        return allocator.dupe(u8, "err");
    }
    return allocator.dupe(u8, "exit=-");
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
