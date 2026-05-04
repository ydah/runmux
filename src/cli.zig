const std = @import("std");

pub const version = "0.1.0";
pub const default_config_path = "runmux.json";

pub const Command = enum {
    run,
    check,
    init,
    list,
    help,
    version,
};

pub const Options = struct {
    command: Command = .run,
    config_path: []const u8 = default_config_path,
    profile_name: ?[]const u8 = null,
    plain: bool = false,
    log_dir: ?[]const u8 = null,
};

pub const ParseError = error{
    MissingValue,
    UnknownCommand,
    UnknownOption,
    TooManyCommands,
};

pub fn parse(args: []const [:0]const u8) ParseError!Options {
    var result: Options = .{};
    var command_seen = false;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.command = .help;
            return result;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            result.command = .version;
            return result;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            result.config_path = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            result.profile_name = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--plain")) {
            result.plain = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--log-dir")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            result.log_dir = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;

        if (command_seen) return error.TooManyCommands;
        command_seen = true;
        result.command = parseCommand(arg) orelse return error.UnknownCommand;
    }

    return result;
}

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "run")) return .run;
    if (std.mem.eql(u8, arg, "check")) return .check;
    if (std.mem.eql(u8, arg, "init")) return .init;
    if (std.mem.eql(u8, arg, "list")) return .list;
    return null;
}

pub const help_text =
    \\runmux - lightweight TUI command runner
    \\
    \\Usage:
    \\  runmux run [--config runmux.json] [--profile dev] [--plain] [--log-dir logs]
    \\  runmux check [--config runmux.json] [--profile dev]
    \\  runmux init [--config runmux.json]
    \\  runmux list [--config runmux.json] [--profile dev]
    \\  runmux --help
    \\  runmux --version
    \\
    \\TUI keys:
    \\  Up/k, Down/j select   Enter start/stop   r restart
    \\  a start all           x stop all         Tab log mode
    \\  / search              s/f/u filter       p pause follow
    \\  ? help                q or Ctrl+C quit
    \\
;

test "parse defaults to run" {
    const args = [_][:0]const u8{"runmux"};
    const opts = try parse(&args);
    try std.testing.expectEqual(Command.run, opts.command);
    try std.testing.expectEqualStrings(default_config_path, opts.config_path);
}

test "parse command and options" {
    const args = [_][:0]const u8{ "runmux", "list", "--config", "x.json", "--profile", "dev" };
    const opts = try parse(&args);
    try std.testing.expectEqual(Command.list, opts.command);
    try std.testing.expectEqualStrings("x.json", opts.config_path);
    try std.testing.expectEqualStrings("dev", opts.profile_name.?);
}

test "parse plain run option" {
    const args = [_][:0]const u8{ "runmux", "run", "--plain" };
    const opts = try parse(&args);
    try std.testing.expectEqual(Command.run, opts.command);
    try std.testing.expect(opts.plain);
}

test "parse log dir option" {
    const args = [_][:0]const u8{ "runmux", "run", "--log-dir", "logs" };
    const opts = try parse(&args);
    try std.testing.expectEqual(Command.run, opts.command);
    try std.testing.expectEqualStrings("logs", opts.log_dir.?);
}
