const std = @import("std");
const toml_config = @import("toml_config.zig");

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

pub const HealthSpec = struct {
    cmd: ?[]const u8,
    argv: []const []const u8,
    interval_ms: u32 = 1000,
    timeout_ms: u32 = 5000,
    retries: u32 = 30,
};

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const ProcessSpec = struct {
    name: []const u8,
    cmd: ?[]const u8,
    argv: []const []const u8,
    depends_on: []const []const u8,
    cwd: []const u8,
    env: []const EnvVar,
    shell: bool,
    autostart: bool,
    critical: bool,
    restart: RestartSpec,
    log: LogSpec,
    health: ?HealthSpec,
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
    depends_on: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    shell: ?bool = null,
    autostart: ?bool = null,
    critical: ?bool = null,
    restart: ?RawRestartSpec = null,
    log: ?RawLogSpec = null,
    health: ?RawHealthSpec = null,
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

const RawHealthSpec = struct {
    cmd: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    interval_ms: ?u32 = null,
    timeout_ms: ?u32 = null,
    retries: ?u32 = null,
};

pub const LoadedConfig = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(RawConfig),
    profile: ResolvedProfile,

    pub fn deinit(self: *LoadedConfig) void {
        for (self.profile.processes) |process| {
            self.allocator.free(process.argv);
            self.allocator.free(process.depends_on);
            freeHealth(self.allocator, process.health);
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
    if (isTomlPath(path)) {
        return parseAndResolveTomlString(allocator, io, bytes, profile_name, diagnostics);
    }
    return parseAndResolveString(allocator, io, bytes, profile_name, diagnostics);
}

pub fn parseAndResolveTomlString(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    profile_name: ?[]const u8,
    diagnostics: *Diagnostics,
) !LoadedConfig {
    const json_bytes = toml_config.toJson(allocator, bytes) catch |err| {
        return diagnostics.fail("config error: invalid TOML: {s}", .{@errorName(err)});
    };
    defer allocator.free(json_bytes);
    return parseAndResolveString(allocator, io, json_bytes, profile_name, diagnostics);
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
            allocator.free(process.depends_on);
            freeHealth(allocator, process.health);
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
    try validateDependencyGraph(allocator, raw_profile.name, raw_profile.processes, diagnostics);

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
            raw_profile.processes,
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
    raw_processes: []RawProcessSpec,
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

    const depends_on = if (raw.depends_on) |source| blk: {
        const copy = try allocator.alloc([]const u8, source.len);
        errdefer allocator.free(copy);
        for (source, 0..) |dependency, dependency_index| {
            if (dependency.len == 0) {
                return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": depends_on must not contain empty names", .{
                    profile_name,
                    raw.name,
                });
            }
            if (std.mem.eql(u8, dependency, raw.name)) {
                return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": depends_on cannot include itself", .{
                    profile_name,
                    raw.name,
                });
            }
            if (!rawProcessExists(raw_processes, dependency)) {
                return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": dependency \"{s}\" not found", .{
                    profile_name,
                    raw.name,
                    dependency,
                });
            }
            copy[dependency_index] = dependency;
        }
        break :blk copy;
    } else try allocator.alloc([]const u8, 0);
    errdefer allocator.free(depends_on);

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

    const health = try resolveHealth(allocator, profile_name, raw.name, raw.health, diagnostics);
    errdefer freeHealth(allocator, health);

    const env = try resolveEnv(allocator, profile_name, raw.name, raw.env, diagnostics);
    errdefer allocator.free(env);

    const cwd = raw.cwd orelse defaults.cwd;
    try validateCwd(io, profile_name, raw.name, cwd, diagnostics);
    const shell = raw.shell orelse defaults.shell;
    if (raw.cmd) |cmd| {
        if (!shell and containsAsciiWhitespace(cmd)) {
            return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": shell=false cmd cannot contain whitespace; use argv instead", .{
                profile_name,
                raw.name,
            });
        }
    }

    return .{
        .name = raw.name,
        .cmd = raw.cmd,
        .argv = argv,
        .depends_on = depends_on,
        .cwd = cwd,
        .env = env,
        .shell = shell,
        .autostart = raw.autostart orelse defaults.autostart,
        .critical = raw.critical orelse false,
        .restart = restart,
        .log = log,
        .health = health,
    };
}

fn containsAsciiWhitespace(value: []const u8) bool {
    for (value) |byte| {
        switch (byte) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => return true,
            else => {},
        }
    }
    return false;
}

fn rawProcessExists(processes: []RawProcessSpec, name: []const u8) bool {
    for (processes) |process| {
        if (std.mem.eql(u8, process.name, name)) return true;
    }
    return false;
}

const DependencyVisit = enum {
    none,
    visiting,
    visited,
};

fn validateDependencyGraph(
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    processes: []RawProcessSpec,
    diagnostics: *Diagnostics,
) !void {
    const visits = try allocator.alloc(DependencyVisit, processes.len);
    defer allocator.free(visits);
    @memset(visits, .none);

    for (processes, 0..) |_, index| {
        try visitDependency(profile_name, processes, index, visits, diagnostics);
    }
}

fn visitDependency(
    profile_name: []const u8,
    processes: []RawProcessSpec,
    index: usize,
    visits: []DependencyVisit,
    diagnostics: *Diagnostics,
) !void {
    switch (visits[index]) {
        .visited => return,
        .visiting => return diagnostics.fail("config error: profile \"{s}\": dependency cycle includes process \"{s}\"", .{
            profile_name,
            processes[index].name,
        }),
        .none => {},
    }

    visits[index] = .visiting;
    if (processes[index].depends_on) |dependencies| {
        for (dependencies) |dependency| {
            const dependency_index = rawProcessIndex(processes, dependency) orelse {
                return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": dependency \"{s}\" not found", .{
                    profile_name,
                    processes[index].name,
                    dependency,
                });
            };
            try visitDependency(profile_name, processes, dependency_index, visits, diagnostics);
        }
    }
    visits[index] = .visited;
}

fn rawProcessIndex(processes: []RawProcessSpec, name: []const u8) ?usize {
    for (processes, 0..) |process, index| {
        if (std.mem.eql(u8, process.name, name)) return index;
    }
    return null;
}

fn resolveHealth(
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    process_name: []const u8,
    raw: ?RawHealthSpec,
    diagnostics: *Diagnostics,
) !?HealthSpec {
    const raw_health = raw orelse return null;
    const has_cmd = raw_health.cmd != null;
    const has_argv = raw_health.argv != null;
    if (has_cmd == has_argv) {
        return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": health requires exactly one of cmd or argv", .{
            profile_name,
            process_name,
        });
    }

    const argv = if (raw_health.argv) |source| blk: {
        if (source.len == 0) {
            return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": health.argv must not be empty", .{
                profile_name,
                process_name,
            });
        }
        const copy = try allocator.alloc([]const u8, source.len);
        @memcpy(copy, source);
        break :blk copy;
    } else try allocator.alloc([]const u8, 0);
    errdefer allocator.free(argv);

    const interval_ms = raw_health.interval_ms orelse 1000;
    if (interval_ms == 0) {
        return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": health.interval_ms must be at least 1", .{
            profile_name,
            process_name,
        });
    }
    const retries = raw_health.retries orelse 30;
    if (retries == 0) {
        return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": health.retries must be at least 1", .{
            profile_name,
            process_name,
        });
    }
    const timeout_ms = raw_health.timeout_ms orelse 5000;
    if (timeout_ms == 0) {
        return diagnostics.fail("config error: profile \"{s}\", process \"{s}\": health.timeout_ms must be at least 1", .{
            profile_name,
            process_name,
        });
    }

    return .{
        .cmd = raw_health.cmd,
        .argv = argv,
        .interval_ms = interval_ms,
        .timeout_ms = timeout_ms,
        .retries = retries,
    };
}

fn freeHealth(allocator: std.mem.Allocator, health: ?HealthSpec) void {
    if (health) |spec| allocator.free(spec.argv);
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

fn isTomlPath(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".toml");
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
    \\          "depends_on": ["clock"],
    \\          "health": {
    \\            "argv": ["/bin/sh", "-c", "exit 0"],
    \\            "interval_ms": 1000,
    \\            "timeout_ms": 5000,
    \\            "retries": 3
    \\          },
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

test "config_resolves_dependencies" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"db","cmd":"echo db"},{"name":"api","cmd":"echo api","depends_on":["db"]}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var loaded = try parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("db", loaded.profile.processes[1].depends_on[0]);
}

test "config_rejects_unknown_dependency" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"echo api","depends_on":["db"]}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.ConfigInvalid, parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.message.?, "dependency") != null);
}

test "config_rejects_dependency_cycle" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"echo api","depends_on":["web"]},{"name":"web","cmd":"echo web","depends_on":["api"]}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.ConfigInvalid, parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.message.?, "cycle") != null);
}

test "config_resolves_health_check" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"sleep 1","health":{"argv":["/bin/sh","-c","exit 0"],"interval_ms":10,"retries":2}}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var loaded = try parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics);
    defer loaded.deinit();

    const health = loaded.profile.processes[0].health.?;
    try std.testing.expectEqual(@as(u32, 10), health.interval_ms);
    try std.testing.expectEqual(@as(u32, 5000), health.timeout_ms);
    try std.testing.expectEqual(@as(u32, 2), health.retries);
    try std.testing.expectEqualStrings("/bin/sh", health.argv[0]);
}

test "config_rejects_invalid_health_check" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"sleep 1","health":{"interval_ms":0}}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.ConfigInvalid, parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.message.?, "health") != null);
}

test "config_rejects_invalid_health_timeout" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"sleep 1","health":{"argv":["/bin/sh","-c","exit 0"],"timeout_ms":0}}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.ConfigInvalid, parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.message.?, "timeout") != null);
}

test "config_rejects_shell_false_cmd_with_whitespace" {
    const data =
        \\{"version":1,"default_profile":"dev","profiles":[{"name":"dev","processes":[
        \\{"name":"api","cmd":"echo 1","shell":false}]}]}
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.ConfigInvalid, parseAndResolveString(std.testing.allocator, std.testing.io, data, null, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.message.?, "shell=false") != null);
}

test "config_resolves_toml" {
    const data =
        \\version = 1
        \\default_profile = "dev"
        \\
        \\[defaults]
        \\cwd = "."
        \\autostart = true
        \\
        \\[[profiles]]
        \\name = "dev"
        \\
        \\[[profiles.processes]]
        \\name = "db"
        \\cmd = "echo db"
        \\
        \\[[profiles.processes]]
        \\name = "api"
        \\argv = ["/bin/sh", "-c", "echo api"]
        \\depends_on = ["db"]
        \\critical = true
        \\
        \\[profiles.processes.health]
        \\argv = ["/bin/sh", "-c", "exit 0"]
        \\interval_ms = 10
        \\timeout_ms = 100
        \\retries = 2
    ;

    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var loaded = try parseAndResolveTomlString(std.testing.allocator, std.testing.io, data, null, &diagnostics);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("dev", loaded.profile.name);
    try std.testing.expectEqual(@as(usize, 2), loaded.profile.processes.len);
    try std.testing.expectEqualStrings("db", loaded.profile.processes[1].depends_on[0]);
    try std.testing.expect(loaded.profile.processes[1].critical);
    try std.testing.expectEqual(@as(u32, 10), loaded.profile.processes[1].health.?.interval_ms);
    try std.testing.expectEqual(@as(u32, 100), loaded.profile.processes[1].health.?.timeout_ms);
}
