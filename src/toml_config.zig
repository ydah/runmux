const std = @import("std");

pub const TomlError = error{InvalidToml} || std.mem.Allocator.Error;

const Context = enum {
    root,
    defaults,
    defaults_restart,
    defaults_log,
    profile,
    process,
    process_restart,
    process_log,
    process_health,
    process_env,
};

const TomlValue = union(enum) {
    string: []const u8,
    bool: bool,
    int: u32,
    string_array: []const []const u8,
};

const RestartBuilder = struct {
    policy: ?[]const u8 = null,
    max_restarts: ?u32 = null,
    delay_ms: ?u32 = null,

    fn hasAny(self: RestartBuilder) bool {
        return self.policy != null or self.max_restarts != null or self.delay_ms != null;
    }
};

const LogBuilder = struct {
    max_lines: ?u32 = null,
    strip_ansi: ?bool = null,

    fn hasAny(self: LogBuilder) bool {
        return self.max_lines != null or self.strip_ansi != null;
    }
};

const HealthBuilder = struct {
    set: bool = false,
    cmd: ?[]const u8 = null,
    argv_set: bool = false,
    argv: std.ArrayList([]const u8) = .empty,
    interval_ms: ?u32 = null,
    retries: ?u32 = null,

    fn hasAny(self: HealthBuilder) bool {
        return self.set or self.cmd != null or self.argv_set or self.interval_ms != null or self.retries != null;
    }
};

const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

const ProcessBuilder = struct {
    name: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    argv_set: bool = false,
    argv: std.ArrayList([]const u8) = .empty,
    depends_on_set: bool = false,
    depends_on: std.ArrayList([]const u8) = .empty,
    cwd: ?[]const u8 = null,
    env: std.ArrayList(EnvPair) = .empty,
    shell: ?bool = null,
    autostart: ?bool = null,
    critical: ?bool = null,
    restart: RestartBuilder = .{},
    log: LogBuilder = .{},
    health: HealthBuilder = .{},
};

const ProfileBuilder = struct {
    name: ?[]const u8 = null,
    processes: std.ArrayList(ProcessBuilder) = .empty,
};

const DefaultsBuilder = struct {
    cwd: ?[]const u8 = null,
    shell: ?bool = null,
    autostart: ?bool = null,
    restart: RestartBuilder = .{},
    log: LogBuilder = .{},

    fn hasAny(self: DefaultsBuilder) bool {
        return self.cwd != null or self.shell != null or self.autostart != null or self.restart.hasAny() or self.log.hasAny();
    }
};

const ConfigBuilder = struct {
    version: ?u32 = null,
    default_profile: ?[]const u8 = null,
    defaults: DefaultsBuilder = .{},
    profiles: std.ArrayList(ProfileBuilder) = .empty,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    config: ConfigBuilder = .{},
    context: Context = .root,
    current_profile_index: ?usize = null,
    current_process_index: ?usize = null,

    fn parse(self: *Parser) TomlError!void {
        var lines = std.mem.splitScalar(u8, self.bytes, '\n');
        while (lines.next()) |raw_line| {
            const without_comment = stripComment(raw_line);
            const line = std.mem.trim(u8, without_comment, " \t\r");
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "[[")) {
                try self.parseArrayTable(line);
                continue;
            }
            if (line[0] == '[') {
                try self.parseTable(line);
                continue;
            }
            try self.parseAssignment(line);
        }
    }

    fn parseArrayTable(self: *Parser, line: []const u8) TomlError!void {
        if (!std.mem.endsWith(u8, line, "]]")) return error.InvalidToml;
        const section = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
        if (std.mem.eql(u8, section, "profiles")) {
            try self.config.profiles.append(self.allocator, .{});
            self.current_profile_index = self.config.profiles.items.len - 1;
            self.current_process_index = null;
            self.context = .profile;
            return;
        }
        if (std.mem.eql(u8, section, "profiles.processes")) {
            const profile = try self.currentProfile();
            try profile.processes.append(self.allocator, .{});
            self.current_process_index = profile.processes.items.len - 1;
            self.context = .process;
            return;
        }
        return error.InvalidToml;
    }

    fn parseTable(self: *Parser, line: []const u8) TomlError!void {
        if (!std.mem.endsWith(u8, line, "]")) return error.InvalidToml;
        const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
        if (std.mem.eql(u8, section, "defaults")) {
            self.context = .defaults;
            return;
        }
        if (std.mem.eql(u8, section, "defaults.restart")) {
            self.context = .defaults_restart;
            return;
        }
        if (std.mem.eql(u8, section, "defaults.log")) {
            self.context = .defaults_log;
            return;
        }
        if (std.mem.eql(u8, section, "profiles.processes.restart")) {
            _ = try self.currentProcess();
            self.context = .process_restart;
            return;
        }
        if (std.mem.eql(u8, section, "profiles.processes.log")) {
            _ = try self.currentProcess();
            self.context = .process_log;
            return;
        }
        if (std.mem.eql(u8, section, "profiles.processes.health")) {
            const process = try self.currentProcess();
            process.health.set = true;
            self.context = .process_health;
            return;
        }
        if (std.mem.eql(u8, section, "profiles.processes.env")) {
            _ = try self.currentProcess();
            self.context = .process_env;
            return;
        }
        return error.InvalidToml;
    }

    fn parseAssignment(self: *Parser, line: []const u8) TomlError!void {
        const equals = findEquals(line) orelse return error.InvalidToml;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const raw_value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len == 0 or raw_value.len == 0) return error.InvalidToml;

        const value = try parseValue(self.allocator, raw_value);
        switch (self.context) {
            .root => try self.assignRoot(key, value),
            .defaults => try self.assignDefaults(key, value),
            .defaults_restart => try assignRestart(key, value, &self.config.defaults.restart),
            .defaults_log => try assignLog(key, value, &self.config.defaults.log),
            .profile => try self.assignProfile(key, value),
            .process => try self.assignProcess(key, value),
            .process_restart => {
                const process = try self.currentProcess();
                try assignRestart(key, value, &process.restart);
            },
            .process_log => {
                const process = try self.currentProcess();
                try assignLog(key, value, &process.log);
            },
            .process_health => try self.assignHealth(key, value),
            .process_env => try self.assignEnv(key, value),
        }
    }

    fn assignRoot(self: *Parser, key: []const u8, value: TomlValue) TomlError!void {
        if (std.mem.eql(u8, key, "version")) {
            self.config.version = try expectInt(value);
            return;
        }
        if (std.mem.eql(u8, key, "default_profile")) {
            self.config.default_profile = try expectString(value);
            return;
        }
        return error.InvalidToml;
    }

    fn assignDefaults(self: *Parser, key: []const u8, value: TomlValue) TomlError!void {
        if (std.mem.eql(u8, key, "cwd")) {
            self.config.defaults.cwd = try expectString(value);
            return;
        }
        if (std.mem.eql(u8, key, "shell")) {
            self.config.defaults.shell = try expectBool(value);
            return;
        }
        if (std.mem.eql(u8, key, "autostart")) {
            self.config.defaults.autostart = try expectBool(value);
            return;
        }
        return error.InvalidToml;
    }

    fn assignProfile(self: *Parser, key: []const u8, value: TomlValue) TomlError!void {
        const profile = try self.currentProfile();
        if (std.mem.eql(u8, key, "name")) {
            profile.name = try expectString(value);
            return;
        }
        return error.InvalidToml;
    }

    fn assignProcess(self: *Parser, key: []const u8, value: TomlValue) TomlError!void {
        const process = try self.currentProcess();
        if (std.mem.eql(u8, key, "name")) {
            process.name = try expectString(value);
            return;
        }
        if (std.mem.eql(u8, key, "cmd")) {
            process.cmd = try expectString(value);
            return;
        }
        if (std.mem.eql(u8, key, "argv")) {
            process.argv_set = true;
            process.argv.clearRetainingCapacity();
            for (try expectStringArray(value)) |item| try process.argv.append(self.allocator, item);
            return;
        }
        if (std.mem.eql(u8, key, "depends_on")) {
            process.depends_on_set = true;
            process.depends_on.clearRetainingCapacity();
            for (try expectStringArray(value)) |item| try process.depends_on.append(self.allocator, item);
            return;
        }
        if (std.mem.eql(u8, key, "cwd")) {
            process.cwd = try expectString(value);
            return;
        }
        if (std.mem.eql(u8, key, "shell")) {
            process.shell = try expectBool(value);
            return;
        }
        if (std.mem.eql(u8, key, "autostart")) {
            process.autostart = try expectBool(value);
            return;
        }
        if (std.mem.eql(u8, key, "critical")) {
            process.critical = try expectBool(value);
            return;
        }
        return error.InvalidToml;
    }

    fn assignHealth(self: *Parser, key: []const u8, value: TomlValue) TomlError!void {
        const process = try self.currentProcess();
        process.health.set = true;
        if (std.mem.eql(u8, key, "cmd")) {
            process.health.cmd = try expectString(value);
            return;
        }
        if (std.mem.eql(u8, key, "argv")) {
            process.health.argv_set = true;
            process.health.argv.clearRetainingCapacity();
            for (try expectStringArray(value)) |item| try process.health.argv.append(self.allocator, item);
            return;
        }
        if (std.mem.eql(u8, key, "interval_ms")) {
            process.health.interval_ms = try expectInt(value);
            return;
        }
        if (std.mem.eql(u8, key, "retries")) {
            process.health.retries = try expectInt(value);
            return;
        }
        return error.InvalidToml;
    }

    fn assignEnv(self: *Parser, key: []const u8, value: TomlValue) TomlError!void {
        const process = try self.currentProcess();
        try process.env.append(self.allocator, .{
            .key = key,
            .value = try expectString(value),
        });
    }

    fn currentProfile(self: *Parser) TomlError!*ProfileBuilder {
        const index = self.current_profile_index orelse return error.InvalidToml;
        if (index >= self.config.profiles.items.len) return error.InvalidToml;
        return &self.config.profiles.items[index];
    }

    fn currentProcess(self: *Parser) TomlError!*ProcessBuilder {
        const profile = try self.currentProfile();
        const index = self.current_process_index orelse return error.InvalidToml;
        if (index >= profile.processes.items.len) return error.InvalidToml;
        return &profile.processes.items[index];
    }
};

pub fn toJson(allocator: std.mem.Allocator, bytes: []const u8) TomlError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser: Parser = .{
        .allocator = arena.allocator(),
        .bytes = bytes,
    };
    try parser.parse();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeConfigJson(allocator, &out, parser.config);
    return out.toOwnedSlice(allocator);
}

fn assignRestart(key: []const u8, value: TomlValue, restart: *RestartBuilder) TomlError!void {
    if (std.mem.eql(u8, key, "policy")) {
        restart.policy = try expectString(value);
        return;
    }
    if (std.mem.eql(u8, key, "max_restarts")) {
        restart.max_restarts = try expectInt(value);
        return;
    }
    if (std.mem.eql(u8, key, "delay_ms")) {
        restart.delay_ms = try expectInt(value);
        return;
    }
    return error.InvalidToml;
}

fn assignLog(key: []const u8, value: TomlValue, log: *LogBuilder) TomlError!void {
    if (std.mem.eql(u8, key, "max_lines")) {
        log.max_lines = try expectInt(value);
        return;
    }
    if (std.mem.eql(u8, key, "strip_ansi")) {
        log.strip_ansi = try expectBool(value);
        return;
    }
    return error.InvalidToml;
}

fn expectString(value: TomlValue) TomlError![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidToml,
    };
}

fn expectBool(value: TomlValue) TomlError!bool {
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidToml,
    };
}

fn expectInt(value: TomlValue) TomlError!u32 {
    return switch (value) {
        .int => |number| number,
        else => error.InvalidToml,
    };
}

fn expectStringArray(value: TomlValue) TomlError![]const []const u8 {
    return switch (value) {
        .string_array => |items| items,
        else => error.InvalidToml,
    };
}

fn parseValue(allocator: std.mem.Allocator, raw: []const u8) TomlError!TomlValue {
    if (raw.len == 0) return error.InvalidToml;
    if (raw[0] == '[') return .{ .string_array = try parseStringArray(allocator, raw) };
    if (raw[0] == '"' or raw[0] == '\'') return .{ .string = try parseQuotedString(allocator, raw) };
    if (std.mem.eql(u8, raw, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, raw, "false")) return .{ .bool = false };
    return .{ .int = std.fmt.parseUnsigned(u32, raw, 10) catch return error.InvalidToml };
}

fn parseStringArray(allocator: std.mem.Allocator, raw: []const u8) TomlError![]const []const u8 {
    if (raw.len < 2 or raw[0] != '[' or raw[raw.len - 1] != ']') return error.InvalidToml;
    const inner = raw[1 .. raw.len - 1];
    var result: std.ArrayList([]const u8) = .empty;

    var index: usize = 0;
    while (index < inner.len) {
        while (index < inner.len and isSpace(inner[index])) index += 1;
        if (index >= inner.len) break;
        if (inner[index] != '"' and inner[index] != '\'') return error.InvalidToml;

        const start = index;
        index += 1;
        var escaped = false;
        while (index < inner.len) : (index += 1) {
            const byte = inner[index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (inner[start] == '"' and byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == inner[start]) {
                index += 1;
                break;
            }
        } else return error.InvalidToml;

        try result.append(allocator, try parseQuotedString(allocator, inner[start..index]));
        while (index < inner.len and isSpace(inner[index])) index += 1;
        if (index >= inner.len) break;
        if (inner[index] != ',') return error.InvalidToml;
        index += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn parseQuotedString(allocator: std.mem.Allocator, raw: []const u8) TomlError![]const u8 {
    if (raw.len < 2) return error.InvalidToml;
    const quote = raw[0];
    if ((quote != '"' and quote != '\'') or raw[raw.len - 1] != quote) return error.InvalidToml;
    if (quote == '\'') return raw[1 .. raw.len - 1];

    var result: std.ArrayList(u8) = .empty;
    var index: usize = 1;
    while (index + 1 < raw.len) : (index += 1) {
        const byte = raw[index];
        if (byte != '\\') {
            try result.append(allocator, byte);
            continue;
        }

        index += 1;
        if (index + 1 > raw.len) return error.InvalidToml;
        const escaped = raw[index];
        try result.append(allocator, switch (escaped) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => return error.InvalidToml,
        });
    }
    return result.toOwnedSlice(allocator);
}

fn stripComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (quote) |active| {
            if (escaped) {
                escaped = false;
            } else if (active == '"' and byte == '\\') {
                escaped = true;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '#') return line[0..index];
    }
    return line;
}

fn findEquals(line: []const u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (quote) |active| {
            if (escaped) {
                escaped = false;
            } else if (active == '"' and byte == '\\') {
                escaped = true;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '=') return index;
    }
    return null;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn writeConfigJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), config: ConfigBuilder) TomlError!void {
    try out.append(allocator, '{');
    var first = true;
    if (config.version) |version| try writeIntField(allocator, out, &first, "version", version);
    if (config.default_profile) |default_profile| try writeStringField(allocator, out, &first, "default_profile", default_profile);
    if (config.defaults.hasAny()) {
        try beginField(allocator, out, &first, "defaults");
        try writeDefaultsJson(allocator, out, config.defaults);
    }
    try beginField(allocator, out, &first, "profiles");
    try out.append(allocator, '[');
    for (config.profiles.items, 0..) |profile, index| {
        if (index > 0) try out.append(allocator, ',');
        try writeProfileJson(allocator, out, profile);
    }
    try out.append(allocator, ']');
    try out.append(allocator, '}');
}

fn writeDefaultsJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), defaults: DefaultsBuilder) TomlError!void {
    try out.append(allocator, '{');
    var first = true;
    if (defaults.cwd) |cwd| try writeStringField(allocator, out, &first, "cwd", cwd);
    if (defaults.shell) |shell| try writeBoolField(allocator, out, &first, "shell", shell);
    if (defaults.autostart) |autostart| try writeBoolField(allocator, out, &first, "autostart", autostart);
    if (defaults.restart.hasAny()) {
        try beginField(allocator, out, &first, "restart");
        try writeRestartJson(allocator, out, defaults.restart);
    }
    if (defaults.log.hasAny()) {
        try beginField(allocator, out, &first, "log");
        try writeLogJson(allocator, out, defaults.log);
    }
    try out.append(allocator, '}');
}

fn writeProfileJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), profile: ProfileBuilder) TomlError!void {
    try out.append(allocator, '{');
    var first = true;
    if (profile.name) |name| try writeStringField(allocator, out, &first, "name", name);
    try beginField(allocator, out, &first, "processes");
    try out.append(allocator, '[');
    for (profile.processes.items, 0..) |process, index| {
        if (index > 0) try out.append(allocator, ',');
        try writeProcessJson(allocator, out, process);
    }
    try out.append(allocator, ']');
    try out.append(allocator, '}');
}

fn writeProcessJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), process: ProcessBuilder) TomlError!void {
    try out.append(allocator, '{');
    var first = true;
    if (process.name) |name| try writeStringField(allocator, out, &first, "name", name);
    if (process.cmd) |cmd| try writeStringField(allocator, out, &first, "cmd", cmd);
    if (process.argv_set) try writeStringArrayField(allocator, out, &first, "argv", process.argv.items);
    if (process.depends_on_set) try writeStringArrayField(allocator, out, &first, "depends_on", process.depends_on.items);
    if (process.cwd) |cwd| try writeStringField(allocator, out, &first, "cwd", cwd);
    if (process.env.items.len > 0) {
        try beginField(allocator, out, &first, "env");
        try writeEnvJson(allocator, out, process.env.items);
    }
    if (process.shell) |shell| try writeBoolField(allocator, out, &first, "shell", shell);
    if (process.autostart) |autostart| try writeBoolField(allocator, out, &first, "autostart", autostart);
    if (process.critical) |critical| try writeBoolField(allocator, out, &first, "critical", critical);
    if (process.restart.hasAny()) {
        try beginField(allocator, out, &first, "restart");
        try writeRestartJson(allocator, out, process.restart);
    }
    if (process.log.hasAny()) {
        try beginField(allocator, out, &first, "log");
        try writeLogJson(allocator, out, process.log);
    }
    if (process.health.hasAny()) {
        try beginField(allocator, out, &first, "health");
        try writeHealthJson(allocator, out, process.health);
    }
    try out.append(allocator, '}');
}

fn writeRestartJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), restart: RestartBuilder) TomlError!void {
    try out.append(allocator, '{');
    var first = true;
    if (restart.policy) |policy| try writeStringField(allocator, out, &first, "policy", policy);
    if (restart.max_restarts) |max_restarts| try writeIntField(allocator, out, &first, "max_restarts", max_restarts);
    if (restart.delay_ms) |delay_ms| try writeIntField(allocator, out, &first, "delay_ms", delay_ms);
    try out.append(allocator, '}');
}

fn writeLogJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), log: LogBuilder) TomlError!void {
    try out.append(allocator, '{');
    var first = true;
    if (log.max_lines) |max_lines| try writeIntField(allocator, out, &first, "max_lines", max_lines);
    if (log.strip_ansi) |strip_ansi| try writeBoolField(allocator, out, &first, "strip_ansi", strip_ansi);
    try out.append(allocator, '}');
}

fn writeHealthJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), health: HealthBuilder) TomlError!void {
    try out.append(allocator, '{');
    var first = true;
    if (health.cmd) |cmd| try writeStringField(allocator, out, &first, "cmd", cmd);
    if (health.argv_set) try writeStringArrayField(allocator, out, &first, "argv", health.argv.items);
    if (health.interval_ms) |interval_ms| try writeIntField(allocator, out, &first, "interval_ms", interval_ms);
    if (health.retries) |retries| try writeIntField(allocator, out, &first, "retries", retries);
    try out.append(allocator, '}');
}

fn writeEnvJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), env: []const EnvPair) TomlError!void {
    try out.append(allocator, '{');
    for (env, 0..) |entry, index| {
        if (index > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, entry.key);
        try out.append(allocator, ':');
        try appendJsonString(allocator, out, entry.value);
    }
    try out.append(allocator, '}');
}

fn writeStringField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: []const u8,
) TomlError!void {
    try beginField(allocator, out, first, name);
    try appendJsonString(allocator, out, value);
}

fn writeStringArrayField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    values: []const []const u8,
) TomlError!void {
    try beginField(allocator, out, first, name);
    try out.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, value);
    }
    try out.append(allocator, ']');
}

fn writeBoolField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: bool,
) TomlError!void {
    try beginField(allocator, out, first, name);
    try out.appendSlice(allocator, if (value) "true" else "false");
}

fn writeIntField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: u32,
) TomlError!void {
    try beginField(allocator, out, first, name);
    try out.print(allocator, "{d}", .{value});
}

fn beginField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
) TomlError!void {
    if (first.*) {
        first.* = false;
    } else {
        try out.append(allocator, ',');
    }
    try appendJsonString(allocator, out, name);
    try out.append(allocator, ':');
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) TomlError!void {
    try out.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                try out.appendSlice(allocator, "\\u00");
                try out.append(allocator, hex[byte >> 4]);
                try out.append(allocator, hex[byte & 0x0f]);
            },
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '"');
}

test "toml_config_converts_runmux_schema_to_json" {
    const data =
        \\version = 1
        \\default_profile = "dev"
        \\
        \\[defaults]
        \\cwd = "."
        \\shell = true
        \\autostart = true
        \\
        \\[defaults.restart]
        \\policy = "never"
        \\max_restarts = 0
        \\delay_ms = 1000
        \\
        \\[defaults.log]
        \\max_lines = 100
        \\strip_ansi = false
        \\
        \\[[profiles]]
        \\name = "dev"
        \\
        \\[[profiles.processes]]
        \\name = "db"
        \\cmd = "echo db"
        \\
        \\[profiles.processes.env]
        \\PORT = "5432"
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
        \\retries = 2
    ;

    const json = try toJson(std.testing.allocator, data);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"default_profile\":\"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"depends_on\":[\"db\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"PORT\":\"5432\"") != null);
}
