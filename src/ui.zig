const std = @import("std");
const vaxis = @import("vaxis");
const config = @import("config.zig");
const log_store = @import("log_store.zig");
const supervisor_mod = @import("supervisor.zig");
const ui_snapshot = @import("ui_snapshot.zig");

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
        const last_text = try lastResultAlloc(allocator, process);
        defer allocator.free(last_text);
        const line = try ui_snapshot.formatProcessRow(allocator, .{
            .selected = selected,
            .status = process.status,
            .critical = process.spec.critical,
            .name = process.spec.name,
            .pid = process.pid,
            .restart_count = process.restart_count,
            .last_result = last_text,
        });
        defer allocator.free(line);
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
        const prefix = try ui_snapshot.formatLogPrefix(allocator, line);
        defer allocator.free(prefix);
        print(log_window, 0, row, prefix, streamStyle(line.stream, true));
        const prefix_width: u16 = @intCast(@min(prefix.len, @as(usize, log_window.width)));
        if (prefix_width < log_window.width) {
            try printAnsi(allocator, log_window, prefix_width, row, line.text, streamStyle(line.stream, false));
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

fn printAnsi(
    allocator: std.mem.Allocator,
    window: vaxis.Window,
    col: u16,
    row: u16,
    text: []const u8,
    base_style: vaxis.Style,
) !void {
    if (row >= window.height or col >= window.width) return;

    var segments: std.ArrayList(vaxis.Segment) = .empty;
    defer segments.deinit(allocator);

    var style = base_style;
    var chunk_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != 0x1b) {
            index += 1;
            continue;
        }

        if (chunk_start < index) {
            try segments.append(allocator, .{ .text = text[chunk_start..index], .style = style });
        }
        index = consumeAnsi(text, index, base_style, &style);
        chunk_start = index;
    }
    if (chunk_start < text.len) {
        try segments.append(allocator, .{ .text = text[chunk_start..], .style = style });
    }
    if (segments.items.len == 0) return;

    _ = window.print(segments.items, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
}

fn consumeAnsi(text: []const u8, start: usize, base_style: vaxis.Style, style: *vaxis.Style) usize {
    if (start + 1 >= text.len) return start + 1;
    if (text[start + 1] != '[') return start + 2;

    var end = start + 2;
    while (end < text.len) : (end += 1) {
        const byte = text[end];
        if (byte >= 0x40 and byte <= 0x7e) break;
    }
    if (end >= text.len) return text.len;
    if (text[end] == 'm') applySgr(text[start + 2 .. end], base_style, style);
    return end + 1;
}

fn applySgr(params: []const u8, base_style: vaxis.Style, style: *vaxis.Style) void {
    if (params.len == 0) {
        style.* = base_style;
        return;
    }

    var codes: [32]u16 = undefined;
    var code_count: usize = 0;
    var index: usize = 0;
    while (index <= params.len) {
        const end = std.mem.indexOfScalarPos(u8, params, index, ';') orelse params.len;
        if (code_count >= codes.len) break;
        codes[code_count] = if (end == index) 0 else std.fmt.parseInt(u16, params[index..end], 10) catch 0;
        code_count += 1;
        if (end == params.len) break;
        index = end + 1;
    }

    index = 0;
    while (index < code_count) {
        const consumed = applySgrCode(codes[0..code_count], index, base_style, style);
        index += if (consumed == 0) 1 else consumed;
    }
}

fn applySgrCode(codes: []const u16, index: usize, base_style: vaxis.Style, style: *vaxis.Style) usize {
    const code = codes[index];
    switch (code) {
        0 => style.* = base_style,
        1 => style.bold = true,
        2 => style.dim = true,
        3 => style.italic = true,
        4 => style.ul_style = .single,
        7 => style.reverse = true,
        22 => {
            style.bold = false;
            style.dim = false;
        },
        23 => style.italic = false,
        24 => style.ul_style = .off,
        27 => style.reverse = false,
        30...37 => style.fg = .{ .index = @intCast(code - 30) },
        39 => style.fg = .default,
        40...47 => style.bg = .{ .index = @intCast(code - 40) },
        49 => style.bg = .default,
        90...97 => style.fg = .{ .index = @intCast((code - 90) + 8) },
        100...107 => style.bg = .{ .index = @intCast((code - 100) + 8) },
        38, 48 => return applyExtendedColor(codes, index, code == 38, style),
        else => {},
    }
    return 1;
}

fn applyExtendedColor(codes: []const u16, index: usize, foreground: bool, style: *vaxis.Style) usize {
    if (index + 2 >= codes.len) return 1;
    switch (codes[index + 1]) {
        5 => {
            const color: vaxis.Color = .{ .index = @intCast(@min(codes[index + 2], 255)) };
            if (foreground) style.fg = color else style.bg = color;
            return 3;
        },
        2 => {
            if (index + 4 >= codes.len) return 1;
            const color: vaxis.Color = .{ .rgb = .{
                @intCast(@min(codes[index + 2], 255)),
                @intCast(@min(codes[index + 3], 255)),
                @intCast(@min(codes[index + 4], 255)),
            } };
            if (foreground) style.fg = color else style.bg = color;
            return 5;
        },
        else => return 1,
    }
}

test "ui_apply_sgr_extended_colors" {
    var style: vaxis.Style = .{};
    applySgr("38;5;196;48;2;1;2;3", .{}, &style);

    switch (style.fg) {
        .index => |value| try std.testing.expectEqual(@as(u8, 196), value),
        else => return error.TestUnexpectedResult,
    }
    switch (style.bg) {
        .rgb => |value| try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &value),
        else => return error.TestUnexpectedResult,
    }
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
