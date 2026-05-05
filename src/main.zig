const std = @import("std");
const runmux = @import("runmux");

const cli = runmux.cli;
const config = runmux.config;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const parsed = cli.parse(args) catch |err| {
        try printErr(io, "error: {s}\n\n{s}", .{ @errorName(err), cli.help_text });
        std.process.exit(2);
    };

    switch (parsed.command) {
        .help => try printOut(io, "{s}", .{cli.help_text}),
        .version => try printOut(io, "runmux {s}\n", .{cli.version}),
        .init => try commandInit(io, parsed.config_path, parsed.force),
        .check => try commandCheck(allocator, io, parsed.config_path, parsed.profile_name),
        .list => try commandList(allocator, io, parsed.config_path, parsed.profile_name),
        .run => try commandRun(allocator, io, init.environ_map, parsed.config_path, parsed.profile_name, parsed.plain, parsed.log_dir, parsed.exit_on_critical_failure, parsed.theme_name),
    }
}

fn commandInit(io: std.Io, path: []const u8, force: bool) !void {
    const cwd = std.Io.Dir.cwd();
    if (force) {
        try cwd.writeFile(io, .{
            .sub_path = path,
            .data = config.sample_config,
            .flags = .{},
        });
        try printOut(io, "wrote {s}\n", .{path});
        return;
    }

    cwd.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try cwd.writeFile(io, .{
                .sub_path = path,
                .data = config.sample_config,
                .flags = .{ .exclusive = true },
            });
            try printOut(io, "created {s}\n", .{path});
            return;
        },
        else => return err,
    };

    try printErr(io, "error: {s} already exists\n", .{path});
    std.process.exit(2);
}

fn commandCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    profile_name: ?[]const u8,
) !void {
    var diagnostics = config.Diagnostics.init(allocator);
    defer diagnostics.deinit();

    var loaded = config.loadAndResolveFile(allocator, io, path, profile_name, &diagnostics) catch |err| {
        try printDiagnostics(io, err, &diagnostics);
        std.process.exit(2);
    };
    defer loaded.deinit();

    try printOut(io, "config ok: {s} profile={s} processes={d}\n", .{
        path,
        loaded.profile.name,
        loaded.profile.processes.len,
    });
}

fn commandList(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    profile_name: ?[]const u8,
) !void {
    var diagnostics = config.Diagnostics.init(allocator);
    defer diagnostics.deinit();

    var loaded = config.loadAndResolveFile(allocator, io, path, profile_name, &diagnostics) catch |err| {
        try printDiagnostics(io, err, &diagnostics);
        std.process.exit(2);
    };
    defer loaded.deinit();

    try printOut(io, "profile {s}\n", .{loaded.profile.name});
    for (loaded.profile.processes) |process| {
        try printOut(io, "- {s}\n", .{process.name});
        if (process.cmd) |cmd| {
            try printOut(io, "  cmd: {s}\n", .{cmd});
        } else {
            const argv_text = try stringArrayDisplayAlloc(allocator, process.argv);
            defer allocator.free(argv_text);
            try printOut(io, "  argv: {s}\n", .{argv_text});
        }

        try printOut(io, "  cwd: {s}\n", .{process.cwd});
        try printOut(io, "  autostart: {}\n", .{process.autostart});
        try printOut(io, "  critical: {}\n", .{process.critical});
        try printOut(io, "  shell: {}\n", .{process.shell});
        try printOut(io, "  dependency_failure: {s}\n", .{@tagName(process.dependency_failure)});

        if (process.depends_on.len > 0) {
            const dependencies = try stringArrayDisplayAlloc(allocator, process.depends_on);
            defer allocator.free(dependencies);
            try printOut(io, "  depends_on: {s}\n", .{dependencies});
        } else {
            try printOut(io, "  depends_on: []\n", .{});
        }

        try printOut(io, "  restart: policy={s} max_restarts={d} delay_ms={d}\n", .{
            @tagName(process.restart.policy),
            process.restart.max_restarts,
            process.restart.delay_ms,
        });
        try printOut(io, "  log: max_lines={d} strip_ansi={}\n", .{
            process.log.max_lines,
            process.log.strip_ansi,
        });

        if (process.health) |health| {
            if (health.cmd) |cmd| {
                try printOut(io, "  health: cmd={s} interval_ms={d} timeout_ms={d} retries={d}\n", .{
                    cmd,
                    health.interval_ms,
                    health.timeout_ms,
                    health.retries,
                });
            } else {
                const argv_text = try stringArrayDisplayAlloc(allocator, health.argv);
                defer allocator.free(argv_text);
                try printOut(io, "  health: argv={s} interval_ms={d} timeout_ms={d} retries={d}\n", .{
                    argv_text,
                    health.interval_ms,
                    health.timeout_ms,
                    health.retries,
                });
            }
        } else {
            try printOut(io, "  health: none\n", .{});
        }
    }
}

fn commandRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    path: []const u8,
    profile_name: ?[]const u8,
    plain: bool,
    log_dir: ?[]const u8,
    exit_on_critical_failure: bool,
    theme_name: ?[]const u8,
) !void {
    var diagnostics = config.Diagnostics.init(allocator);
    defer diagnostics.deinit();

    var loaded = config.loadAndResolveFile(allocator, io, path, profile_name, &diagnostics) catch |err| {
        try printDiagnostics(io, err, &diagnostics);
        std.process.exit(2);
    };
    defer loaded.deinit();

    const run_options: runmux.supervisor.Options = .{
        .log_dir = log_dir,
        .exit_on_critical_failure = exit_on_critical_failure,
        .theme = parseTheme(theme_name) catch |err| {
            try printErr(io, "error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        },
    };

    if (plain) {
        runmux.plain.run(allocator, io, environ_map, &loaded.profile, run_options) catch |err| {
            switch (err) {
                error.ChildFailed => std.process.exit(4),
                else => {
                    try printErr(io, "error: plain run failed: {s}\n", .{@errorName(err)});
                    std.process.exit(5);
                },
            }
        };
        return;
    }

    runmux.ui.run(allocator, io, environ_map, &loaded.profile, run_options) catch |err| {
        try printErr(io, "error: TUI failed: {s}\n", .{@errorName(err)});
        std.process.exit(3);
    };
}

fn parseTheme(theme_name: ?[]const u8) !runmux.supervisor.Theme {
    const name = theme_name orelse return .dark;
    if (std.mem.eql(u8, name, "dark")) return .dark;
    if (std.mem.eql(u8, name, "light")) return .light;
    if (std.mem.eql(u8, name, "mono")) return .mono;
    return error.InvalidTheme;
}

fn printDiagnostics(io: std.Io, err: anyerror, diagnostics: *const config.Diagnostics) !void {
    if (diagnostics.message) |message| {
        try printErr(io, "{s}\n", .{message});
    } else {
        try printErr(io, "error: {s}\n", .{@errorName(err)});
    }
}

fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn stringArrayDisplayAlloc(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');
    for (items, 0..) |item, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try appendQuotedDisplay(allocator, &out, item);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendQuotedDisplay(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '"');
}

test "string_array_display_quotes_values" {
    const text = try stringArrayDisplayAlloc(std.testing.allocator, &.{ "run", "say \"hi\"", "a\\b" });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[\"run\", \"say \\\"hi\\\"\", \"a\\\\b\"]", text);
}
