const std = @import("std");
const vaxis = @import("vaxis");
const config = @import("config.zig");
const log_store = @import("log_store.zig");
const supervisor_mod = @import("supervisor.zig");

const Supervisor = supervisor_mod.Supervisor;
const Theme = supervisor_mod.Theme;

const VaxisEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    profile: *const config.ResolvedProfile,
    options: supervisor_mod.Options,
) !void {
    var supervisor = try Supervisor.init(allocator, io, environ_map, profile, options);
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
    if (supervisor.input_mode != .none) {
        handleTextInputKey(supervisor, key);
        return;
    }
    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
        supervisor.should_quit = true;
        return;
    }
    if (key.matches('/', .{})) {
        supervisor.beginSearch();
        return;
    }
    if (key.matches('s', .{})) {
        supervisor.cycleStreamFilter();
        return;
    }
    if (key.matches('f', .{})) {
        supervisor.toggleProcessFilter();
        return;
    }
    if (key.matches('u', .{})) {
        supervisor.clearFilters();
        return;
    }
    if (key.matches('i', .{})) {
        supervisor.beginStdinInput();
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

fn handleTextInputKey(supervisor: *Supervisor, key: vaxis.Key) void {
    if (key.codepoint == vaxis.Key.enter) {
        switch (supervisor.input_mode) {
            .search => supervisor.applySearch(),
            .stdin => supervisor.sendStdinInput(),
            .none => {},
        }
        return;
    }
    if (key.codepoint == vaxis.Key.escape) {
        supervisor.cancelInput();
        return;
    }
    if (key.codepoint == vaxis.Key.backspace) {
        supervisor.deleteInputByte();
        return;
    }
    if (key.text) |text| {
        if (!key.mods.ctrl and !key.mods.alt and !key.mods.super and text.len > 0) {
            supervisor.appendInputText(text);
        }
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
    if (supervisor.show_help) renderHelp(root, supervisor.options.theme);
}

const Palette = struct {
    header: vaxis.Style,
    footer: vaxis.Style,
    popup: vaxis.Style,
    popup_title: vaxis.Style,
};

fn palette(theme: Theme) Palette {
    return switch (theme) {
        .dark => .{
            .header = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 4 }, .bold = true },
            .footer = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 8 } },
            .popup = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } },
            .popup_title = .{ .fg = .{ .index = 14 }, .bg = .{ .index = 0 }, .bold = true },
        },
        .light => .{
            .header = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 }, .bold = true },
            .footer = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } },
            .popup = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 15 } },
            .popup_title = .{ .fg = .{ .index = 4 }, .bg = .{ .index = 15 }, .bold = true },
        },
        .mono => .{
            .header = .{ .bold = true, .reverse = true },
            .footer = .{ .reverse = true },
            .popup = .{},
            .popup_title = .{ .bold = true },
        },
    };
}

fn renderHeader(root: vaxis.Window, allocator: std.mem.Allocator, supervisor: *Supervisor) !void {
    const selected_name = if (supervisor.selectedProcess()) |process| process.spec.name else "-";
    const filter_text = try filterSummaryAlloc(allocator, supervisor);
    const text = try std.fmt.allocPrint(allocator, " runmux | profile: {s} | running: {d}/{d} | selected: {s} | logs: {s}{s}{s}", .{
        supervisor.profile.name,
        supervisor.runningCount(),
        supervisor.processes.len,
        selected_name,
        @tagName(supervisor.log_mode),
        if (supervisor.paused) " | paused" else "",
        filter_text,
    });
    print(root, 0, 0, text, palette(supervisor.options.theme).header);
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
        print(process_window, 0, row, line, if (selected) .{ .reverse = true, .bold = true } else statusStyle(process.status, supervisor.options.theme));
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

    var filtered: std.ArrayList(log_store.LogLine) = .empty;
    defer filtered.deinit(allocator);
    for (logs) |line| {
        if (logMatches(supervisor, line)) {
            try filtered.append(allocator, line);
        }
    }

    const visible: usize = content_height;
    const visible_logs = filtered.items;
    const end = if (supervisor.paused_log_end) |paused_end| @min(paused_end, visible_logs.len) else visible_logs.len;
    const start = if (end > visible) end - visible else 0;
    row = top;
    for (visible_logs[start..end]) |line| {
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
    const row = root.height - 2;
    const colors = palette(supervisor.options.theme);
    switch (supervisor.input_mode) {
        .search => {
            print(root, 0, row, " Search: type query, Enter apply, Esc cancel", colors.footer);
            print(root, 0, row + 1, supervisor.search_input.items, colors.footer);
            return;
        },
        .stdin => {
            print(root, 0, row, " Send stdin: type one line, Enter send, Esc cancel", colors.footer);
            print(root, 0, row + 1, supervisor.search_input.items, colors.footer);
            return;
        },
        .none => {},
    }
    print(root, 0, row, " Up/Down j/k select  Enter start/stop  r restart  a start-all  x stop-all  Tab logs", colors.footer);
    print(root, 0, row + 1, " / search  i stdin  s stream-filter  f process-filter  u clear  p pause  ? help  q quit", colors.footer);
}

fn renderHelp(root: vaxis.Window, theme: Theme) void {
    const colors = palette(theme);
    const width: u16 = @min(root.width - 4, 64);
    const height: u16 = 11;
    const x: i17 = @intCast((root.width - width) / 2);
    const y: i17 = @intCast((root.height - height) / 2);
    const popup = root.child(.{
        .x_off = x,
        .y_off = y,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .glyphs = .single_square, .style = colors.popup },
    });
    popup.clear();
    const style: vaxis.Style = colors.popup;
    print(popup, 1, 0, "runmux keys", colors.popup_title);
    print(popup, 1, 2, "j/k or arrows   select process", style);
    print(popup, 1, 3, "Enter           start or stop selected", style);
    print(popup, 1, 4, "r               restart selected", style);
    print(popup, 1, 5, "a / x           start all / stop all", style);
    print(popup, 1, 6, "Tab             selected or all logs", style);
    print(popup, 1, 7, "/ s f u         search, stream, process, clear", style);
    print(popup, 1, 8, "i               send one line to selected stdin", style);
    print(popup, 1, 9, "p               pause or resume log follow", style);
    print(popup, 1, 10, "q or Ctrl+C     quit and stop children", style);
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

fn statusStyle(status: supervisor_mod.ProcessStatus, theme: Theme) vaxis.Style {
    if (theme == .mono) {
        return switch (status) {
            .running, .failed, .restarting, .starting, .stopping => .{ .bold = true },
            else => .{},
        };
    }
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

fn filterSummaryAlloc(allocator: std.mem.Allocator, supervisor: *const Supervisor) ![]const u8 {
    if (supervisor.input_mode == .search) {
        return std.fmt.allocPrint(allocator, " | search: /{s}", .{supervisor.search_input.items});
    }
    if (supervisor.input_mode == .stdin) {
        const selected_name = if (supervisor.processes.len > 0) supervisor.processes[supervisor.selected_index].spec.name else "-";
        return std.fmt.allocPrint(allocator, " | stdin: {s}", .{selected_name});
    }

    var parts: std.ArrayList(u8) = .empty;
    errdefer parts.deinit(allocator);
    if (supervisor.filter_query) |query| {
        try appendFmt(allocator, &parts, " query=\"{s}\"", .{query});
    }
    if (supervisor.filter_stream) |stream| {
        try appendFmt(allocator, &parts, " stream={s}", .{@tagName(stream)});
    }
    if (supervisor.filter_process_id) |process_id| {
        try appendFmt(allocator, &parts, " process={s}", .{processNameById(supervisor, process_id) orelse "?"});
    }
    if (parts.items.len == 0) return allocator.dupe(u8, "");
    const owned = try parts.toOwnedSlice(allocator);
    defer allocator.free(owned);
    return std.fmt.allocPrint(allocator, " | filter:{s}", .{owned});
}

fn appendFmt(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn processNameById(supervisor: *const Supervisor, process_id: u32) ?[]const u8 {
    for (supervisor.processes) |process| {
        if (process.id == process_id) return process.spec.name;
    }
    return null;
}

fn logMatches(supervisor: *const Supervisor, line: log_store.LogLine) bool {
    if (supervisor.filter_stream) |stream| {
        if (line.stream != stream) return false;
    }
    if (supervisor.filter_process_id) |process_id| {
        if (line.process_id != process_id) return false;
    }
    if (supervisor.filter_query) |query| {
        if (std.mem.indexOf(u8, line.text, query) == null and std.mem.indexOf(u8, line.process_name, query) == null) {
            return false;
        }
    }
    return true;
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
