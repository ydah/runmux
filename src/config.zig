const std = @import("std");

pub const ConfigError = error{ConfigInvalid};

pub const RestartPolicy = enum {
    never,
    on_failure,
    always,
};

pub const RestartSpec = struct {
    policy: RestartPolicy = .never,
    max_restarts: u32 = 0,
    delay_ms: u32 = 1000,
};

pub const LogSpec = struct {
    max_lines: u32 = 2000,
    strip_ansi: bool = true,
};

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const ProcessSpec = struct {
    name: []const u8,
    cmd: ?[]const u8,
    argv: []const []const u8,
    cwd: []const u8,
    env: []const EnvVar,
    shell: bool,
    autostart: bool,
    critical: bool,
    restart: RestartSpec,
    log: LogSpec,
};

pub const ResolvedProfile = struct {
    name: []const u8,
    processes: []ProcessSpec,
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    message: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        if (self.message) |message| self.allocator.free(message);
        self.message = null;
    }

    pub fn fail(self: *Diagnostics, comptime fmt: []const u8, args: anytype) ConfigError {
        self.deinit();
        self.message = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
        return error.ConfigInvalid;
    }
};

const RawConfig = struct {
    version: u32,
    default_profile: ?[]const u8 = null,
    defaults: ?RawDefaults = null,
    profiles: []RawProfile,
};

const RawDefaults = struct {
    cwd: ?[]const u8 = null,
    shell: ?bool = null,
    autostart: ?bool = null,
    restart: ?RawRestartSpec = null,
    log: ?RawLogSpec = null,
};

const RawProfile = struct {
    name: []const u8,
    processes: []RawProcessSpec,
};

const RawProcessSpec = struct {
    name: []const u8,
    cmd: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    shell: ?bool = null,
    autostart: ?bool = null,
    critical: ?bool = null,
    restart: ?RawRestartSpec = null,
    log: ?RawLogSpec = null,
};

const RawRestartSpec = struct {
    policy: ?[]const u8 = null,
    max_restarts: ?u32 = null,
    delay_ms: ?u32 = null,
};

const RawLogSpec = struct {
    max_lines: ?u32 = null,
    strip_ansi: ?bool = null,
};

pub const LoadedConfig = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(RawConfig),
    profile: ResolvedProfile,

    pub fn deinit(self: *LoadedConfig) void {
        for (self.profile.processes) |process| {
            self.allocator.free(process.argv);
            self.allocator.free(process.env);
        }
        self.allocator.free(self.profile.processes);
        self.parsed.deinit();
    }
};

pub fn loadAndResolveFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    profile_name: ?[]const u8,
    diagnostics: *Diagnostics,
) !LoadedConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        return diagnostics.fail("config error: unable to read {s}: {s}", .{ path, @errorName(err) });
    };
    defer allocator.free(bytes);
    return parseAndResolveString(allocator, io, bytes, profile_name, diagnostics);
}

pub fn parseAndResolveString(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    profile_name: ?[]const u8,
    diagnostics: *Diagnostics,
) !LoadedConfig {
    const parsed = std.json.parseFromSlice(RawConfig, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        return diagnostics.fail("config error: invalid JSON: {s}", .{@errorName(err)});
    };
    errdefer parsed.deinit();

    const profile = try resolve(allocator, io, parsed.value, profile_name, diagnostics);
    errdefer {
        for (profile.processes) |process| {
            allocator.free(process.argv);
            allocator.free(process.env);
        }
        allocator.free(profile.processes);
    }

    return .{
        .allocator = allocator,
        .parsed = parsed,
        .profile = profile,
    };
}

fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    raw: RawConfig,
    profile_name: ?[]const u8,
    diagnostics: *Diagnostics,
) !ResolvedProfile {
    if (raw.version != 1) {
        return diagnostics.fail("config error: version must be 1, got {d}", .{raw.version});
    }
    if (raw.profiles.len == 0) {
        return diagnostics.fail("config error: profiles must not be empty", .{});
    }

    var profile_names = std.StringHashMap(void).init(allocator);
    defer profile_names.deinit();
    for (raw.profiles) |profile| {
        if (profile.name.len == 0) {
            return diagnostics.fail("config error: profile name must not be empty", .{});
        }
        const entry = try profile_names.getOrPut(profile.name);
        if (entry.found_existing) {
            return diagnostics.fail("config error: duplicate profile name \"{s}\"", .{profile.name});
        }
        entry.value_ptr.* = {};
    }

    const selected_name = profile_name orelse raw.default_profile orelse "default";
    const raw_profile = findProfile(raw.profiles, selected_name) orelse {
        return diagnostics.fail("config error: profile \"{s}\" not found", .{selected_name});
    };
    if (raw_profile.processes.len == 0) {
        return diagnostics.fail("config error: profile \"{s}\": processes must not be empty", .{raw_profile.name});
    }

    const defaults = applyDefaults(raw.defaults);
    var processes = try allocator.alloc(ProcessSpec, raw_profile.processes.len);
    errdefer allocator.free(processes);

    var process_names = std.StringHashMap(void).init(allocator);
    defer process_names.deinit();

    for (raw_profile.processes, 0..) |raw_process, index| {
        processes[index] = try resolveProcess(
            allocator,
            io,
            raw_profile.name,
            raw_process,
            defaults,
            &process_names,
            diagnostics,
        );
    }

    return .{
        .name = raw_profile.name,
        .processes = processes,
    };
}

const Defaults = struct {
    cwd: []const u8 = ".",
    shell: bool = true,
    autostart: bool = true,
    restart: RestartSpec = .{},
    log: LogSpec = .{},
};

fn applyDefaults(raw: ?RawDefaults) Defaults {
    var defaults: Defaults = .{};
    if (raw) |r| {
        if (r.cwd) |cwd| defaults.cwd = cwd;
        if (r.shell) |shell| defaults.shell = shell;
        if (r.autostart) |autostart| defaults.autostart = autostart;
        if (r.restart) |restart| defaults.restart = mergeRestart(defaults.restart, restart) catch defaults.restart;
        if (r.log) |log| defaults.log = mergeLog(defaults.log, log);
    }
    return defaults;
}

fn resolveProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    profile_name: []const u8,
    raw: RawProcessSpec,
    defaults: Defaults,
    process_names: *std.StringHashMap(void),
    diagnostics: *Diagnostics,
) !ProcessSpec {
    if (raw.name.len == 0) {
        return diagnostics.fail("config error: profile \"{s}\": process name must not be empty", .{profile_name});
    }
    const name_entry = try process_names.getOrPut(raw.name);
    if (name_entry.found_existing) {
        return diagnostics.fail("config error: profile \"{s}\": duplicate process name \"{s}\"", .{
            profile_name,
            raw.name,
        });
    }
    name_entry.value_ptr.* = {};

    const has_cmd = raw.cmd != null;
    const has_argv = raw.argv != null;
    if (has_cmd == has_argv) {
        return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": exactly one of cmd or argv is required", .{
            profile_name,
            raw.name,
        });
    }

    const argv = if (raw.argv) |source| blk: {
        if (source.len == 0) {
            return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": argv must not be empty", .{
                profile_name,
                raw.name,
            });
        }
        const copy = try allocator.alloc([]const u8, source.len);
        @memcpy(copy, source);
        break :blk copy;
    } else try allocator.alloc([]const u8, 0);
    errdefer allocator.free(argv);

    const restart = if (raw.restart) |restart|
        mergeRestart(defaults.restart, restart) catch {
            return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": invalid restart policy", .{
                profile_name,
                raw.name,
            });
        }
    else
        defaults.restart;

    const log = if (raw.log) |log_spec| mergeLog(defaults.log, log_spec) else defaults.log;
    if (log.max_lines == 0) {
        return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": log.max_lines must be at least 1", .{
            profile_name,
            raw.name,
        });
    }

    const env = try resolveEnv(allocator, profile_name, raw.name, raw.env, diagnostics);
    errdefer allocator.free(env);

    const cwd = raw.cwd orelse defaults.cwd;
    try validateCwd(io, profile_name, raw.name, cwd, diagnostics);

    return .{
        .name = raw.name,
        .cmd = raw.cmd,
        .argv = argv,
        .cwd = cwd,
        .env = env,
        .shell = raw.shell orelse defaults.shell,
        .autostart = raw.autostart orelse defaults.autostart,
        .critical = raw.critical orelse false,
        .restart = restart,
        .log = log,
    };
}

fn resolveEnv(
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    process_name: []const u8,
    raw_env: ?std.json.Value,
    diagnostics: *Diagnostics,
) ![]EnvVar {
    const env_value = raw_env orelse return allocator.alloc(EnvVar, 0);
    if (env_value != .object) {
        return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": env must be an object", .{
            profile_name,
            process_name,
        });
    }

    var object = env_value.object;
    var vars = try allocator.alloc(EnvVar, object.count());
    errdefer allocator.free(vars);

    var index: usize = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) {
            return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": env.{s} must be a string", .{
                profile_name,
                process_name,
                entry.key_ptr.*,
            });
        }
        vars[index] = .{
            .key = entry.key_ptr.*,
            .value = entry.value_ptr.string,
        };
        index += 1;
    }
    return vars;
}

fn validateCwd(
    io: std.Io,
    profile_name: []const u8,
    process_name: []const u8,
    cwd: []const u8,
    diagnostics: *Diagnostics,
) !void {
    const dir = if (std.fs.path.isAbsolute(cwd))
        std.Io.Dir.openDirAbsolute(io, cwd, .{}) catch |err| {
            return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": cwd \"{s}\" is invalid: {s}", .{
                profile_name,
                process_name,
                cwd,
                @errorName(err),
            });
        }
    else
        std.Io.Dir.cwd().openDir(io, cwd, .{}) catch |err| {
            return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": cwd \"{s}\" is invalid: {s}", .{
                profile_name,
                process_name,
                cwd,
                @errorName(err),
            });
        };
    dir.close(io);
}

fn mergeRestart(base: RestartSpec, raw: RawRestartSpec) !RestartSpec {
    var result = base;
    if (raw.policy) |policy| result.policy = try parseRestartPolicy(policy);
    if (raw.max_restarts) |max_restarts| result.max_restarts = max_restarts;
    if (raw.delay_ms) |delay_ms| result.delay_ms = delay_ms;
    return result;
}

fn mergeLog(base: LogSpec, raw: RawLogSpec) LogSpec {
    var result = base;
    if (raw.max_lines) |max_lines| result.max_lines = max_lines;
    if (raw.strip_ansi) |strip_ansi| result.strip_ansi = strip_ansi;
    return result;
}

fn parseRestartPolicy(value: []const u8) !RestartPolicy {
    if (std.mem.eql(u8, value, "never")) return .never;
    if (std.mem.eql(u8, value, "on_failure")) return .on_failure;
    if (std.mem.eql(u8, value, "always")) return .always;
    return error.InvalidRestartPolicy;
}

fn findProfile(profiles: []RawProfile, name: []const u8) ?RawProfile {
    for (profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return profile;
    }
    return null;
}

pub const sample_config =
    \\{
    \\  "version": 1,
    \\  "default_profile": "dev",
    \\  "defaults": {
    \\    "cwd": ".",
    \\    "shell": true,
    \\    "autostart": true,
    \\    "restart": {
    \\      "policy": "never",
    \\      "max_restarts": 0,
    \\      "delay_ms": 1000
    \\    },
    \\    "log": {
    \\      "max_lines": 1000,
    \\      "strip_ansi": true
    \\    }
    \\  },
    \\  "profiles": [
    \\    {
    \\      "name": "dev",
    \\      "processes": [
    \\        {
    \\          "name": "clock",
    \\          "cmd": "while true; do date; sleep 1; done"
    \\        },
    \\        {
    \\          "name": "stderr-demo",
    \\          "cmd": "while true; do echo warn >&2; sleep 2; done"
    \\        },
    \\        {
    \\          "name": "manual",
    \\          "cmd": "echo manual process; sleep 5",
    \\          "autostart": false
    \\        }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

test "config_valid_sample_passes" {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    var loaded = try parseAndResolveString(std.testing.allocator, std.testing.io, sample_config, null, &diagnostics);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("dev", loaded.profile.name);
    try std.testing.expectEqual(@as(usize, 3), loaded.profile.processes.len);
}

test "config_rejects_duplicate_process_names" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"echo 1"},{"name":"api","cmd":"echo 2"}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.ConfigInvalid, parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.message.?, "duplicate process name") != null);
}

test "config_rejects_cmd_and_argv_together" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"echo 1","argv":["echo","1"]}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.ConfigInvalid, parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.message.?, "exactly one") != null);
}

test "config_rejects_missing_command" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api"}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.ConfigInvalid, parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics));
}

test "config_applies_defaults" {
    const data =
        \\{"version":1,"default_profile":"dev","defaults":{"autostart":false,"restart":{"policy":"on_failure","max_restarts":2},"log":{"max_lines":12}},"profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"echo 1"}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var loaded = try parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics);
    defer loaded.deinit();

    const process = loaded.profile.processes[0];
    try std.testing.expect(!process.autostart);
    try std.testing.expectEqual(RestartPolicy.on_failure, process.restart.policy);
    try std.testing.expectEqual(@as(u32, 2), process.restart.max_restarts);
    try std.testing.expectEqual(@as(u32, 12), process.log.max_lines);
}
