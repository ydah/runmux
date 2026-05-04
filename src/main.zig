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
        .init => try commandInit(io, parsed.config_path),
        .check => try commandCheck(allocator, io, parsed.config_path, parsed.profile_name),
        .list => try commandList(allocator, io, parsed.config_path, parsed.profile_name),
        .run => try commandRun(allocator, io, init.environ_map, parsed.config_path, parsed.profile_name, parsed.plain, parsed.log_dir, parsed.exit_on_critical_failure, parsed.theme_name),
    }
}

fn commandInit(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
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
        const command = process.cmd orelse if (process.argv.len > 0) process.argv[0] else "";
        try printOut(io, "- {s}: {s} cwd={s} autostart={} restart={s}\n", .{
            process.name,
            command,
            process.cwd,
            process.autostart,
            @tagName(process.restart.policy),
        });
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
