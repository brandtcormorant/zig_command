/// zig_command - Standalone CLI argument parsing, routing, and help generation.
///
/// Usage:
///   const cmd = @import("zig_command");
///   const CommandId = enum(u32) { root = 1 };
///   const FlagId = enum(u32) { verbose = 1, count = 2 };
///
///   const schema = cmd.Command{
///       .name = "myapp",
///       .id = @intFromEnum(CommandId.root),
///       .description = "Does useful things",
///       .args = &.{
///           .{ .name = "input", .required = true },
///           .{ .name = "output" },
///       },
///       .flags = &.{
///           .{ .name = "verbose", .id = @intFromEnum(FlagId.verbose), .aliases = &.{"v"}, .default_value = .{ .boolean = false }, .description = "Enable verbose output" },
///           .{ .name = "count", .id = @intFromEnum(FlagId.count), .aliases = &.{"n"}, .kind = .number, .default_value = .{ .number = 1 } },
///       },
///   };
///
///   const result = try cmd.parse(allocator, argv, &schema);
///   defer result.deinit();
///   const verbose = result.getBool("verbose").?;
///   const count = result.getNumber("count").?;
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Command definition with args, flags, and subcommands.
pub const Command = struct {
    name: []const u8,
    id: u32 = 0,
    description: ?[]const u8 = null,
    args: ?[]const ArgDef = null,
    flags: ?[]const FlagDef = null,
    subcommands: ?[]const *const Command = null,
    examples: ?[]const []const u8 = null,
};

/// Positional argument definition.
///
/// `non_empty` makes the validator reject the empty string for this positional.
/// On a non-variadic arg the check fires when the corresponding positional is
/// `""`. On a variadic tail the check fires when ANY positional in the tail is
/// `""` — useful for `loop send <to> <from> <message...>` where every token
/// must carry content.
pub const ArgDef = struct {
    name: []const u8,
    required: bool = true,
    variadic: bool = false,
    non_empty: bool = false,
    description: ?[]const u8 = null,
};

/// Flag definition.
///
/// `name` is the canonical result key and default long CLI spelling.
/// `aliases` are additional CLI spellings without leading dashes. Single-byte
/// aliases are accepted as short flags (`-v`, including combined short groups);
/// longer aliases are accepted as long flags (`--run-id`). `short` is kept as a
/// compatibility field for existing schemas; new callers should use `aliases`.
///
/// `id` is for caller code and remains independent of the public CLI spelling.
/// `default_value` is inserted into parsed results when the user omits the flag;
/// use `ParseResult.wasProvided` when omission must be distinguished from a
/// defaulted value.
///
/// `non_empty` only applies to string flags. When set, the validator rejects
/// flag invocations that supply an empty string (e.g. `--reason ""`,
/// `--session ""`). Boolean and number flags ignore the field.
pub const FlagDef = struct {
    name: []const u8,
    id: u32 = 0,
    aliases: ?[]const []const u8 = null,
    short: ?u8 = null,
    kind: FlagKind = .boolean,
    default_value: ?FlagValue = null,
    non_empty: bool = false,
    description: ?[]const u8 = null,

    pub fn key(self: *const FlagDef) []const u8 {
        return self.name;
    }
};

/// Flag value types.
pub const FlagKind = enum {
    boolean,
    string,
    number,
};

/// Parsed flag value.
pub const FlagValue = union(FlagKind) {
    boolean: bool,
    string: []const u8,
    number: i64,
};

/// Result of parsing argv.
pub const ParseResult = struct {
    allocator: Allocator,
    args: std.ArrayListUnmanaged([]const u8) = .empty,
    flags: std.StringHashMapUnmanaged(FlagValue) = .empty,
    provided_flags: std.StringHashMapUnmanaged(void) = .empty,
    rest: std.ArrayListUnmanaged([]const u8) = .empty,
    command: *const Command,
    parents: std.ArrayListUnmanaged(*const Command) = .empty,
    help_requested: bool = false,

    pub fn deinit(self: *ParseResult) void {
        self.args.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        self.provided_flags.deinit(self.allocator);
        self.rest.deinit(self.allocator);
        self.parents.deinit(self.allocator);
    }

    /// Get the caller-declared id for the matched leaf command.
    pub fn commandId(self: *const ParseResult) u32 {
        return self.command.id;
    }

    /// Get a flag value by name.
    pub fn getFlag(self: *const ParseResult, name: []const u8) ?FlagValue {
        return self.flags.get(name);
    }

    /// Get a flag value by caller-declared id.
    pub fn getFlagById(self: *const ParseResult, id: u32) ?FlagValue {
        if (id == 0) return null;
        if (findFlagById(self.command, id)) |flag| {
            return self.flags.get(flag.key());
        }
        for (self.parents.items) |parent| {
            if (findFlagById(parent, id)) |flag| {
                return self.flags.get(flag.key());
            }
        }
        return null;
    }

    /// True when a flag was explicitly present in argv.
    pub fn wasProvided(self: *const ParseResult, name: []const u8) bool {
        return self.provided_flags.contains(name);
    }

    /// True when a caller-declared flag id was explicitly present in argv.
    pub fn wasProvidedById(self: *const ParseResult, id: u32) bool {
        if (id == 0) return false;
        if (findFlagById(self.command, id)) |flag| {
            return self.wasProvided(flag.key());
        }
        for (self.parents.items) |parent| {
            if (findFlagById(parent, id)) |flag| {
                return self.wasProvided(flag.key());
            }
        }
        return false;
    }

    /// Get a flag as boolean (null if not set).
    pub fn getBool(self: *const ParseResult, name: []const u8) ?bool {
        if (self.flags.get(name)) |val| {
            return switch (val) {
                .boolean => |b| b,
                else => null,
            };
        }
        return null;
    }

    /// Get a flag as string (null if not set).
    pub fn getString(self: *const ParseResult, name: []const u8) ?[]const u8 {
        if (self.flags.get(name)) |val| {
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    /// Get a flag as number (null if not set).
    pub fn getNumber(self: *const ParseResult, name: []const u8) ?i64 {
        if (self.flags.get(name)) |val| {
            return switch (val) {
                .number => |n| n,
                else => null,
            };
        }
        return null;
    }
};

pub const ParseError = error{
    InvalidFlag,
    MissingFlagValue,
    InvalidNumber,
    InvalidDefault,
    UnknownFlag,
    OutOfMemory,
};

/// Parse command-line arguments against a schema.
pub fn parse(allocator: Allocator, argv: []const []const u8, schema: *const Command) ParseError!ParseResult {
    var result = ParseResult{
        .allocator = allocator,
        .command = schema,
    };
    errdefer result.deinit();

    var alias_map = std.AutoHashMapUnmanaged(u8, *const FlagDef).empty;
    defer alias_map.deinit(allocator);

    if (schema.flags) |flags| {
        for (flags) |*flag| {
            if (flag.short) |short| {
                alias_map.put(allocator, short, flag) catch return ParseError.OutOfMemory;
            }
            if (flag.aliases) |aliases| {
                for (aliases) |alias| {
                    if (alias.len == 1) {
                        alias_map.put(allocator, alias[0], flag) catch return ParseError.OutOfMemory;
                    }
                }
            }
        }
    }

    var i: usize = 0;
    while (i < argv.len) {
        const token = argv[i];

        if (std.mem.eql(u8, token, "--")) {
            i += 1;
            while (i < argv.len) : (i += 1) {
                result.rest.append(allocator, argv[i]) catch return ParseError.OutOfMemory;
            }
            break;
        }

        if (token.len > 2 and std.mem.startsWith(u8, token, "--")) {
            i = try parseLongFlag(argv, i, &result, schema, allocator);
            continue;
        }

        if (token.len > 1 and token[0] == '-' and token[1] != '-') {
            i = try parseShortFlags(argv, i, &result, schema, &alias_map, allocator);
            continue;
        }

        if (schema.subcommands) |subcommands| {
            var found_sub: ?*const Command = null;

            for (subcommands) |sub| {
                if (std.mem.eql(u8, token, sub.name)) {
                    found_sub = sub;
                    break;
                }
            }

            if (found_sub) |sub| {
                result.parents.append(allocator, schema) catch return ParseError.OutOfMemory;
                var sub_result = try parse(allocator, argv[i + 1 ..], sub);
                result.command = sub_result.command;

                for (sub_result.args.items) |arg| {
                    result.args.append(allocator, arg) catch return ParseError.OutOfMemory;
                }

                var iter = sub_result.flags.iterator();

                while (iter.next()) |entry| {
                    result.flags.put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch return ParseError.OutOfMemory;
                }

                var provided_iter = sub_result.provided_flags.iterator();

                while (provided_iter.next()) |entry| {
                    result.provided_flags.put(allocator, entry.key_ptr.*, {}) catch return ParseError.OutOfMemory;
                }

                for (sub_result.rest.items) |r| {
                    result.rest.append(allocator, r) catch return ParseError.OutOfMemory;
                }

                for (sub_result.parents.items) |p| {
                    result.parents.append(allocator, p) catch return ParseError.OutOfMemory;
                }

                result.help_requested = sub_result.help_requested;
                try applyDefaults(&result, schema, allocator);
                sub_result.deinit();
                return result;
            }
        }

        result.args.append(allocator, token) catch return ParseError.OutOfMemory;
        i += 1;
    }

    try applyDefaults(&result, schema, allocator);
    return result;
}

fn parseLongFlag(
    argv: []const []const u8,
    start: usize,
    result: *ParseResult,
    schema: *const Command,
    allocator: Allocator,
) ParseError!usize {
    const token = argv[start];
    const flag_part = token[2..];

    var flag_name: []const u8 = undefined;
    var flag_value: ?[]const u8 = null;

    if (std.mem.indexOf(u8, flag_part, "=")) |eq_idx| {
        flag_name = flag_part[0..eq_idx];
        flag_value = flag_part[eq_idx + 1 ..];
    } else {
        flag_name = flag_part;
    }

    if (std.mem.eql(u8, flag_name, "help")) {
        result.help_requested = true;
        return start + 1;
    }

    const flag_def = findFlag(schema, flag_name) orelse {
        return ParseError.UnknownFlag;
    };

    const kind = flag_def.kind;

    if (flag_value) |val| {
        try putProvidedFlag(result, allocator, flag_def, try coerceValue(val, kind));
    } else if (kind == .boolean) {
        try putProvidedFlag(result, allocator, flag_def, .{ .boolean = true });
    } else {
        if (start + 1 < argv.len and !std.mem.startsWith(u8, argv[start + 1], "-")) {
            try putProvidedFlag(result, allocator, flag_def, try coerceValue(argv[start + 1], kind));
            return start + 2;
        } else {
            return ParseError.MissingFlagValue;
        }
    }

    return start + 1;
}

fn parseShortFlags(
    argv: []const []const u8,
    start: usize,
    result: *ParseResult,
    schema: *const Command,
    alias_map: *std.AutoHashMapUnmanaged(u8, *const FlagDef),
    allocator: Allocator,
) ParseError!usize {
    const token = argv[start];
    const chars = token[1..];

    var j: usize = 0;
    while (j < chars.len) : (j += 1) {
        const c = chars[j];

        if (c == 'h') {
            result.help_requested = true;
            continue;
        }

        const flag_def = alias_map.get(c) orelse findFlag(schema, chars[j .. j + 1]) orelse return ParseError.UnknownFlag;
        const kind = flag_def.kind;
        const is_last = j == chars.len - 1;

        if (is_last and kind != .boolean) {
            if (start + 1 < argv.len and !std.mem.startsWith(u8, argv[start + 1], "-")) {
                try putProvidedFlag(result, allocator, flag_def, try coerceValue(argv[start + 1], kind));
                return start + 2;
            } else {
                return ParseError.MissingFlagValue;
            }
        } else {
            try putProvidedFlag(result, allocator, flag_def, .{ .boolean = true });
        }
    }

    return start + 1;
}

fn putProvidedFlag(
    result: *ParseResult,
    allocator: Allocator,
    flag_def: *const FlagDef,
    value: FlagValue,
) ParseError!void {
    const key = flag_def.key();
    result.flags.put(allocator, key, value) catch return ParseError.OutOfMemory;
    result.provided_flags.put(allocator, key, {}) catch return ParseError.OutOfMemory;
}

fn applyDefaults(result: *ParseResult, schema: *const Command, allocator: Allocator) ParseError!void {
    if (schema.flags) |flags| {
        for (flags) |*flag| {
            const default_value = flag.default_value orelse continue;
            if (!flagValueMatchesKind(default_value, flag.kind)) return ParseError.InvalidDefault;
            if (result.flags.contains(flag.key())) continue;
            result.flags.put(allocator, flag.key(), default_value) catch return ParseError.OutOfMemory;
        }
    }
}

fn flagValueMatchesKind(value: FlagValue, kind: FlagKind) bool {
    return switch (value) {
        .boolean => kind == .boolean,
        .string => kind == .string,
        .number => kind == .number,
    };
}

fn findFlag(schema: *const Command, name: []const u8) ?*const FlagDef {
    if (schema.flags) |flags| {
        for (flags) |*flag| {
            if (std.mem.eql(u8, flag.name, name)) {
                return flag;
            }
            if (flag.aliases) |aliases| {
                for (aliases) |alias| {
                    if (std.mem.eql(u8, alias, name)) {
                        return flag;
                    }
                }
            }
        }
    }

    return null;
}

fn findFlagById(schema: *const Command, id: u32) ?*const FlagDef {
    if (schema.flags) |flags| {
        for (flags) |*flag| {
            if (flag.id == id) return flag;
        }
    }
    return null;
}

fn coerceValue(value: []const u8, kind: FlagKind) ParseError!FlagValue {
    return switch (kind) {
        .boolean => .{ .boolean = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") },
        .string => .{ .string = value },
        .number => blk: {
            const num = std.fmt.parseInt(i64, value, 10) catch {
                const f = std.fmt.parseFloat(f64, value) catch return ParseError.InvalidNumber;
                break :blk .{ .number = @intFromFloat(f) };
            };
            break :blk .{ .number = num };
        },
    };
}

/// Structured outcome of validating a ParseResult against its Command schema.
///
/// Each non-ok variant carries the command pointer so callers can render a
/// context-aware message (path breadcrumbs, valid subcommand list, etc). The
/// offending token is included where relevant.
pub const ValidationResult = union(enum) {
    ok,
    missing_required: struct {
        command: *const Command,
    },
    unknown_subcommand: struct {
        command: *const Command,
        token: []const u8,
    },
    unexpected_extra: struct {
        command: *const Command,
        token: []const u8,
    },
    empty_argument: struct {
        command: *const Command,
        arg_name: []const u8,
        position: usize,
    },
    empty_flag: struct {
        command: *const Command,
        flag_name: []const u8,
    },

    /// True when validation passed.
    pub fn isOk(self: ValidationResult) bool {
        return self == .ok;
    }
};

/// Validate parsed result against schema. Returns a tagged ValidationResult
/// that callers render into a user-facing error message.
///
/// Classification order (first match wins):
///   - unknown_subcommand: schema has subcommands, no declared args, and a positional appeared.
///   - unexpected_extra: positional arguments exceed the non-variadic maximum.
///   - missing_required: fewer positionals than the required count — where a
///     required-variadic tail counts as needing at least one positional.
///   - empty_argument: a positional carrying a `non_empty` ArgDef is the empty string.
///     For variadic tails, the check fires on the FIRST empty positional in the tail.
///   - empty_flag: a string flag carrying a `non_empty` FlagDef was supplied as `""`.
///     Walks `schema.flags` in declaration order; first hit wins.
///   - ok
pub fn validate(result: *const ParseResult) ValidationResult {
    const schema = result.command;
    const arg_count = result.args.items.len;

    if (schema.args == null) {
        if (arg_count > 0) {
            if (schema.subcommands != null) {
                return .{ .unknown_subcommand = .{
                    .command = schema,
                    .token = result.args.items[0],
                } };
            }
            return .{ .unexpected_extra = .{
                .command = schema,
                .token = result.args.items[0],
            } };
        }
    } else {
        const arg_defs = schema.args.?;

        var required_count: usize = 0;
        var has_variadic_tail: bool = false;
        for (arg_defs, 0..) |arg_def, i| {
            const is_tail_variadic = arg_def.variadic and i == arg_defs.len - 1;
            if (arg_def.required and !is_tail_variadic) {
                required_count += 1;
            }
            if (is_tail_variadic) {
                has_variadic_tail = true;
                if (arg_def.required) required_count += 1;
            }
        }

        if (!has_variadic_tail and arg_count > arg_defs.len) {
            return .{ .unexpected_extra = .{
                .command = schema,
                .token = result.args.items[arg_defs.len],
            } };
        }

        if (arg_count < required_count) {
            return .{ .missing_required = .{ .command = schema } };
        }

        for (arg_defs, 0..) |arg_def, def_idx| {
            if (!arg_def.non_empty) continue;
            const is_tail_variadic = arg_def.variadic and def_idx == arg_defs.len - 1;
            if (is_tail_variadic) {
                var i: usize = def_idx;
                while (i < arg_count) : (i += 1) {
                    if (result.args.items[i].len == 0) {
                        return .{ .empty_argument = .{
                            .command = schema,
                            .arg_name = arg_def.name,
                            .position = i,
                        } };
                    }
                }
            } else if (def_idx < arg_count and result.args.items[def_idx].len == 0) {
                return .{ .empty_argument = .{
                    .command = schema,
                    .arg_name = arg_def.name,
                    .position = def_idx,
                } };
            }
        }
    }

    if (schema.flags) |flags| {
        for (flags) |flag_def| {
            if (!flag_def.non_empty) continue;
            if (flag_def.kind != .string) continue;
            const value = result.flags.get(flag_def.name) orelse continue;
            const str = switch (value) {
                .string => |s| s,
                else => continue,
            };
            if (str.len == 0) {
                return .{ .empty_flag = .{
                    .command = schema,
                    .flag_name = flag_def.name,
                } };
            }
        }
    }

    return .ok;
}

/// Format help text for a command.
pub fn formatHelp(allocator: Allocator, command: *const Command, parents: []const *const Command) ![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }

    const usage = try std.fmt.allocPrint(allocator, "Usage: ", .{});
    try parts.append(allocator, usage);

    for (parents) |p| {
        const s = try std.fmt.allocPrint(allocator, "{s} ", .{p.name});
        try parts.append(allocator, s);
    }

    const name_part = try std.fmt.allocPrint(allocator, "{s}", .{command.name});
    try parts.append(allocator, name_part);

    if (command.args) |args| {
        for (args) |arg| {
            const s = if (arg.required)
                (if (arg.variadic)
                    try std.fmt.allocPrint(allocator, " <{s}...>", .{arg.name})
                else
                    try std.fmt.allocPrint(allocator, " <{s}>", .{arg.name}))
            else
                (if (arg.variadic)
                    try std.fmt.allocPrint(allocator, " [{s}...]", .{arg.name})
                else
                    try std.fmt.allocPrint(allocator, " [{s}]", .{arg.name}));

            try parts.append(allocator, s);
        }
    }

    if (command.subcommands != null) {
        try parts.append(allocator, try allocator.dupe(u8, " [command]"));
    }

    try parts.append(allocator, try allocator.dupe(u8, "\n"));

    if (command.description) |desc| {
        const s = try std.fmt.allocPrint(allocator, "\n{s}\n", .{desc});
        try parts.append(allocator, s);
    }

    if (command.args) |args| {
        if (args.len > 0) {
            try parts.append(allocator, try allocator.dupe(u8, "\nArguments:\n"));

            for (args) |arg| {
                const s = try std.fmt.allocPrint(allocator, "  {s}", .{arg.name});
                try parts.append(allocator, s);

                if (arg.description) |desc| {
                    const padding = if (arg.name.len < 18) 18 - arg.name.len else 2;
                    const pad = try allocator.alloc(u8, padding);
                    @memset(pad, ' ');
                    try parts.append(allocator, pad);
                    try parts.append(allocator, try allocator.dupe(u8, desc));
                }

                try parts.append(allocator, try allocator.dupe(u8, "\n"));
            }
        }
    }

    try parts.append(allocator, try allocator.dupe(u8, "\nFlags:\n"));

    if (command.flags) |flags| {
        for (flags) |flag| {
            const s = try formatFlagSpellings(allocator, &flag);
            try parts.append(allocator, s);

            if (flag.description) |desc| {
                const name_len = s.len;
                const padding = if (name_len < 20) 20 - name_len else 2;
                const pad = try allocator.alloc(u8, padding);
                @memset(pad, ' ');
                try parts.append(allocator, pad);
                try parts.append(allocator, try allocator.dupe(u8, desc));
            }

            try parts.append(allocator, try allocator.dupe(u8, "\n"));
        }
    }

    try parts.append(allocator, try allocator.dupe(u8, "  -h, --help          Show this help\n"));

    if (command.subcommands) |subcommands| {
        try parts.append(allocator, try allocator.dupe(u8, "\nCommands:\n"));

        for (subcommands) |sub| {
            const s = try std.fmt.allocPrint(allocator, "  {s}", .{sub.name});
            try parts.append(allocator, s);

            if (sub.description) |desc| {
                const padding = if (sub.name.len < 18) 18 - sub.name.len else 2;
                const pad = try allocator.alloc(u8, padding);
                @memset(pad, ' ');
                try parts.append(allocator, pad);
                try parts.append(allocator, try allocator.dupe(u8, desc));
            }

            try parts.append(allocator, try allocator.dupe(u8, "\n"));
        }
    }

    if (command.examples) |examples| {
        try parts.append(allocator, try allocator.dupe(u8, "\nExamples:\n"));

        for (examples) |example| {
            const s = try std.fmt.allocPrint(allocator, "  {s}\n", .{example});
            try parts.append(allocator, s);
        }
    }

    var total_len: usize = 0;

    for (parts.items) |p| {
        total_len += p.len;
    }

    const result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    for (parts.items) |p| {
        @memcpy(result[offset..][0..p.len], p);
        offset += p.len;
    }

    return result;
}

fn formatFlagSpellings(allocator: Allocator, flag: *const FlagDef) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "  ");
    var wrote = false;

    if (flag.short) |short| {
        try appendShortFlagSpelling(allocator, &buf, short, &wrote);
    }

    if (flag.aliases) |aliases| {
        for (aliases) |alias| {
            if (alias.len == 0) continue;
            if (alias.len == 1) {
                if (flag.short != null and flag.short.? == alias[0]) continue;
                try appendShortFlagSpelling(allocator, &buf, alias[0], &wrote);
            } else {
                if (std.mem.eql(u8, alias, flag.name)) continue;
                try appendLongFlagSpelling(allocator, &buf, alias, &wrote);
            }
        }
    }

    try appendLongFlagSpelling(allocator, &buf, flag.name, &wrote);
    return buf.toOwnedSlice(allocator);
}

fn appendShortFlagSpelling(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    short: u8,
    wrote: *bool,
) !void {
    if (wrote.*) try buf.appendSlice(allocator, ", ");
    try buf.append(allocator, '-');
    try buf.append(allocator, short);
    wrote.* = true;
}

fn appendLongFlagSpelling(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    wrote: *bool,
) !void {
    if (wrote.*) try buf.appendSlice(allocator, ", ");
    try buf.appendSlice(allocator, "--");
    try buf.appendSlice(allocator, name);
    wrote.* = true;
}

test "parse basic args" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .args = &.{
            .{ .name = "input" },
            .{ .name = "output", .required = false },
        },
    };

    var result = try parse(allocator, &.{ "file.txt", "out.txt" }, &schema);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.args.items.len);
    try std.testing.expectEqualStrings("file.txt", result.args.items[0]);
    try std.testing.expectEqualStrings("out.txt", result.args.items[1]);
}

test "parse long flags" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "verbose", .kind = .boolean },
            .{ .name = "count", .kind = .number },
            .{ .name = "name", .kind = .string },
        },
    };

    var result = try parse(allocator, &.{ "--verbose", "--count=5", "--name", "foo" }, &schema);
    defer result.deinit();

    try std.testing.expect(result.getBool("verbose").?);
    try std.testing.expectEqual(@as(i64, 5), result.getNumber("count").?);
    try std.testing.expectEqualStrings("foo", result.getString("name").?);
}

test "parse short flags" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "verbose", .short = 'v', .kind = .boolean },
            .{ .name = "count", .short = 'n', .kind = .number },
        },
    };

    var result = try parse(allocator, &.{ "-v", "-n", "10" }, &schema);
    defer result.deinit();

    try std.testing.expect(result.getBool("verbose").?);
    try std.testing.expectEqual(@as(i64, 10), result.getNumber("count").?);
}

test "parse combined short flags" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "all", .short = 'a', .kind = .boolean },
            .{ .name = "verbose", .short = 'v', .kind = .boolean },
        },
    };

    var result = try parse(allocator, &.{"-av"}, &schema);
    defer result.deinit();

    try std.testing.expect(result.getBool("all").?);
    try std.testing.expect(result.getBool("verbose").?);
}

test "parse flag aliases store canonical key" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "run_id", .id = 91, .aliases = &.{ "run-id", "r" }, .kind = .string },
        },
    };

    var long_result = try parse(allocator, &.{ "--run-id", "abc" }, &schema);
    defer long_result.deinit();

    try std.testing.expectEqualStrings("abc", long_result.getString("run_id").?);
    try std.testing.expect(long_result.getString("run-id") == null);

    const by_id = long_result.getFlagById(91).?;
    switch (by_id) {
        .string => |value| try std.testing.expectEqualStrings("abc", value),
        else => try std.testing.expect(false),
    }

    var short_result = try parse(allocator, &.{ "-r", "xyz" }, &schema);
    defer short_result.deinit();

    try std.testing.expectEqualStrings("xyz", short_result.getString("run_id").?);
}

test "parse single-byte aliases in combined short flags" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "all", .aliases = &.{"a"}, .kind = .boolean },
            .{ .name = "verbose", .aliases = &.{"v"}, .kind = .boolean },
        },
    };

    var result = try parse(allocator, &.{"-av"}, &schema);
    defer result.deinit();

    try std.testing.expect(result.getBool("all").?);
    try std.testing.expect(result.getBool("verbose").?);
}

test "format help includes flag aliases" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "run_id", .aliases = &.{ "r", "run-id" }, .kind = .string },
        },
    };

    const help = try formatHelp(allocator, &schema, &.{});
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "-r, --run-id, --run_id") != null);
}

test "parse inserts default flag values" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "verbose", .id = 11, .kind = .boolean, .default_value = .{ .boolean = false } },
            .{ .name = "profile", .id = 12, .kind = .string, .default_value = .{ .string = "local" } },
            .{ .name = "count", .id = 13, .kind = .number, .default_value = .{ .number = 3 } },
        },
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    try std.testing.expect(!result.getBool("verbose").?);
    try std.testing.expectEqualStrings("local", result.getString("profile").?);
    try std.testing.expectEqual(@as(i64, 3), result.getNumber("count").?);
    try std.testing.expect(!result.wasProvided("verbose"));
    try std.testing.expect(!result.wasProvidedById(12));
}

test "parse tracks provided flags separately from defaults" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "verbose", .id = 11, .aliases = &.{"v"}, .kind = .boolean, .default_value = .{ .boolean = false } },
            .{ .name = "profile", .id = 12, .aliases = &.{"profile-name"}, .kind = .string, .default_value = .{ .string = "local" } },
            .{ .name = "count", .id = 13, .aliases = &.{"n"}, .kind = .number, .default_value = .{ .number = 3 } },
        },
    };

    var result = try parse(allocator, &.{ "-v", "--profile-name", "prod", "-n", "9" }, &schema);
    defer result.deinit();

    try std.testing.expect(result.getBool("verbose").?);
    try std.testing.expectEqualStrings("prod", result.getString("profile").?);
    try std.testing.expectEqual(@as(i64, 9), result.getNumber("count").?);
    try std.testing.expect(result.wasProvided("verbose"));
    try std.testing.expect(result.wasProvidedById(12));
    try std.testing.expect(result.wasProvidedById(13));
}

test "parse rejects mismatched default kind" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "count", .kind = .number, .default_value = .{ .string = "3" } },
        },
    };

    try std.testing.expectError(ParseError.InvalidDefault, parse(allocator, &.{}, &schema));
}

test "parse rest args after --" {
    const allocator = std.testing.allocator;

    const schema = Command{ .name = "test" };

    var result = try parse(allocator, &.{ "arg1", "--", "rest1", "rest2" }, &schema);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.args.items.len);
    try std.testing.expectEqual(@as(usize, 2), result.rest.items.len);
    try std.testing.expectEqualStrings("rest1", result.rest.items[0]);
}

test "parse help flag" {
    const allocator = std.testing.allocator;

    const schema = Command{ .name = "test" };

    var result = try parse(allocator, &.{"--help"}, &schema);
    defer result.deinit();

    try std.testing.expect(result.help_requested);
}

test "format help" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "myapp",
        .description = "A test application",
        .args = &.{
            .{ .name = "input", .description = "Input file" },
        },
        .flags = &.{
            .{ .name = "verbose", .short = 'v', .description = "Enable verbose output" },
        },
    };

    const help = try formatHelp(allocator, &schema, &.{});
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "A test application") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--verbose") != null);
}

test "parse subcommand" {
    const allocator = std.testing.allocator;

    const sub_add = Command{
        .name = "add",
        .description = "Add a file",
        .args = &.{
            .{ .name = "file" },
        },
    };

    const schema = Command{
        .name = "git",
        .subcommands = &.{&sub_add},
    };

    var result = try parse(allocator, &.{ "add", "file.txt" }, &schema);
    defer result.deinit();

    try std.testing.expectEqualStrings("add", result.command.name);
    try std.testing.expectEqual(@as(usize, 1), result.args.items.len);
    try std.testing.expectEqualStrings("file.txt", result.args.items[0]);
    try std.testing.expectEqual(@as(usize, 1), result.parents.items.len);
}

test "parse subcommand exposes leaf command id and parent pointer" {
    const allocator = std.testing.allocator;

    const sub_add = Command{
        .name = "add",
        .id = 42,
        .args = &.{
            .{ .name = "file" },
        },
    };

    const schema = Command{
        .name = "git",
        .id = 7,
        .subcommands = &.{&sub_add},
    };

    var result = try parse(allocator, &.{ "add", "file.txt" }, &schema);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 42), result.commandId());
    try std.testing.expectEqual(&sub_add, result.command);
    try std.testing.expectEqual(@as(usize, 1), result.parents.items.len);
    try std.testing.expectEqual(&schema, result.parents.items[0]);
}

test "omitted command and flag ids remain zero" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "verbose", .kind = .boolean },
        },
    };

    var result = try parse(allocator, &.{"--verbose"}, &schema);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), schema.id);
    try std.testing.expectEqual(@as(u32, 0), schema.flags.?[0].id);
    try std.testing.expectEqual(@as(u32, 0), result.commandId());
    try std.testing.expect(result.getBool("verbose").?);
}

test "parse rejects unknown long flag" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "verbose", .kind = .boolean },
        },
    };

    try std.testing.expectError(ParseError.UnknownFlag, parse(allocator, &.{"--bogus"}, &schema));
    try std.testing.expectError(ParseError.UnknownFlag, parse(allocator, &.{"--count=5"}, &schema));
}

test "parse rejects unknown short flag" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "verbose", .short = 'v', .kind = .boolean },
        },
    };

    try std.testing.expectError(ParseError.UnknownFlag, parse(allocator, &.{"-z"}, &schema));
    try std.testing.expectError(ParseError.UnknownFlag, parse(allocator, &.{"-1"}, &schema));
    try std.testing.expectError(ParseError.UnknownFlag, parse(allocator, &.{"-vx"}, &schema));
}

test "validate ok when no args and no positionals" {
    const allocator = std.testing.allocator;

    const schema = Command{ .name = "bare" };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate unexpected_extra when no-args command receives a positional" {
    const allocator = std.testing.allocator;

    const schema = Command{ .name = "bare" };

    var result = try parse(allocator, &.{"oops"}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    try std.testing.expect(!outcome.isOk());
    switch (outcome) {
        .unexpected_extra => |e| {
            try std.testing.expectEqualStrings("oops", e.token);
            try std.testing.expectEqual(&schema, e.command);
        },
        else => try std.testing.expect(false),
    }
}

test "validate unknown_subcommand when parent-only command receives a positional" {
    const allocator = std.testing.allocator;

    const sub_ok = Command{ .name = "ok" };
    const schema = Command{
        .name = "parent",
        .subcommands = &.{&sub_ok},
    };

    var result = try parse(allocator, &.{"bogus"}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .unknown_subcommand => |e| {
            try std.testing.expectEqualStrings("bogus", e.token);
            try std.testing.expectEqual(&schema, e.command);
        },
        else => try std.testing.expect(false),
    }
}

test "validate ok when parent command receives zero positionals" {
    const allocator = std.testing.allocator;

    const sub_ok = Command{ .name = "ok" };
    const schema = Command{
        .name = "parent",
        .subcommands = &.{&sub_ok},
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate missing_required when declared arg is absent" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "one",
        .args = &.{
            .{ .name = "input" },
        },
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .missing_required => |e| try std.testing.expectEqual(&schema, e.command),
        else => try std.testing.expect(false),
    }
}

test "validate ok when declared non-variadic arg count matches" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "one",
        .args = &.{
            .{ .name = "input" },
        },
    };

    var result = try parse(allocator, &.{"file.txt"}, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate unexpected_extra when declared non-variadic is overflown" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "one",
        .args = &.{
            .{ .name = "input" },
        },
    };

    var result = try parse(allocator, &.{ "file.txt", "extra" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .unexpected_extra => |e| {
            try std.testing.expectEqualStrings("extra", e.token);
            try std.testing.expectEqual(&schema, e.command);
        },
        else => try std.testing.expect(false),
    }
}

test "validate ok when optional non-variadic arg is absent" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "one",
        .args = &.{
            .{ .name = "input", .required = false },
        },
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate ok for variadic tail with many positionals" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "many",
        .args = &.{
            .{ .name = "first" },
            .{ .name = "rest", .required = true, .variadic = true },
        },
    };

    var result = try parse(allocator, &.{ "a", "b", "c", "d", "e" }, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate missing_required when variadic tail required but nothing supplied" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "many",
        .args = &.{
            .{ .name = "first" },
            .{ .name = "rest", .required = true, .variadic = true },
        },
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .missing_required => {},
        else => try std.testing.expect(false),
    }
}

test "validate ok when optional variadic tail is absent" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "opt_var",
        .args = &.{
            .{ .name = "files", .required = false, .variadic = true },
        },
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate missing_required when required-variadic is the only arg and none supplied" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "bare_var",
        .args = &.{
            .{ .name = "message", .required = true, .variadic = true },
        },
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .missing_required => {},
        else => try std.testing.expect(false),
    }
}

test "validate missing_required when required non-variadic args present but required-variadic tail empty" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "send_like",
        .args = &.{
            .{ .name = "to" },
            .{ .name = "from" },
            .{ .name = "message", .required = true, .variadic = true },
        },
    };

    var result = try parse(allocator, &.{ "a", "b" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .missing_required => {},
        else => try std.testing.expect(false),
    }
}

test "validate ok when required-variadic tail receives at least one positional" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "send_like",
        .args = &.{
            .{ .name = "to" },
            .{ .name = "from" },
            .{ .name = "message", .required = true, .variadic = true },
        },
    };

    var result = try parse(allocator, &.{ "a", "b", "c" }, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate empty_argument fires when non_empty positional is the empty string" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "named",
        .args = &.{
            .{ .name = "loop", .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{""}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_argument => |e| {
            try std.testing.expectEqualStrings("loop", e.arg_name);
            try std.testing.expectEqual(@as(usize, 0), e.position);
            try std.testing.expectEqual(&schema, e.command);
        },
        else => try std.testing.expect(false),
    }
}

test "validate empty_argument fires on first empty positional in non_empty variadic tail" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "send_like",
        .args = &.{
            .{ .name = "to", .non_empty = true },
            .{ .name = "from", .non_empty = true },
            .{ .name = "message", .required = true, .variadic = true, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{ "the-x", "me", "hello", "", "world" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_argument => |e| {
            try std.testing.expectEqualStrings("message", e.arg_name);
            try std.testing.expectEqual(@as(usize, 3), e.position);
        },
        else => try std.testing.expect(false),
    }
}

test "validate empty_argument fires when non_empty leading arg is empty even with later content" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "send_like",
        .args = &.{
            .{ .name = "to", .non_empty = true },
            .{ .name = "from", .non_empty = true },
            .{ .name = "message", .required = true, .variadic = true, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{ "", "me", "hi" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_argument => |e| {
            try std.testing.expectEqualStrings("to", e.arg_name);
            try std.testing.expectEqual(@as(usize, 0), e.position);
        },
        else => try std.testing.expect(false),
    }
}

test "validate ignores empty positional when non_empty is not set" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "lenient",
        .args = &.{
            .{ .name = "label" },
        },
    };

    var result = try parse(allocator, &.{""}, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate ok when non_empty optional arg is absent" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "filter",
        .args = &.{
            .{ .name = "loop", .required = false, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate empty_argument fires when non_empty optional arg is supplied as empty" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "filter",
        .args = &.{
            .{ .name = "loop", .required = false, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{""}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_argument => |e| {
            try std.testing.expectEqualStrings("loop", e.arg_name);
            try std.testing.expectEqual(@as(usize, 0), e.position);
        },
        else => try std.testing.expect(false),
    }
}

test "validate ok when non_empty variadic-only arg gets several non-empty positionals" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "broadcast_like",
        .args = &.{
            .{ .name = "message", .required = true, .variadic = true, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{ "hello", "town" }, &schema);
    defer result.deinit();

    try std.testing.expect(validate(&result).isOk());
}

test "validate empty_argument fires on bare empty-string for non_empty variadic-only arg" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "broadcast_like",
        .args = &.{
            .{ .name = "message", .required = true, .variadic = true, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{""}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_argument => |e| {
            try std.testing.expectEqualStrings("message", e.arg_name);
            try std.testing.expectEqual(@as(usize, 0), e.position);
        },
        else => try std.testing.expect(false),
    }
}

test "validate missing_required wins over empty_argument when both could fire" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "send_like",
        .args = &.{
            .{ .name = "to", .non_empty = true },
            .{ .name = "from", .non_empty = true },
            .{ .name = "message", .required = true, .variadic = true, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{ "", "me" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .missing_required => {},
        else => try std.testing.expect(false),
    }
}

test "validate empty_flag fires when non_empty string flag is the empty string" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "run_like",
        .flags = &.{
            .{ .name = "session", .short = 's', .kind = .string, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{ "--session", "" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_flag => |e| {
            try std.testing.expectEqualStrings("session", e.flag_name);
        },
        else => try std.testing.expect(false),
    }
}

test "validate empty_flag fires on equal-form too" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "archive_like",
        .flags = &.{
            .{ .name = "reason", .short = 'r', .kind = .string, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{"--reason="}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_flag => |e| {
            try std.testing.expectEqualStrings("reason", e.flag_name);
        },
        else => try std.testing.expect(false),
    }
}

test "validate ok when non_empty string flag is supplied with content" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "run_like",
        .flags = &.{
            .{ .name = "session", .kind = .string, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{ "--session", "abc-123" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    try std.testing.expect(outcome.isOk());
}

test "validate ok when non_empty string flag is absent" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "run_like",
        .flags = &.{
            .{ .name = "session", .kind = .string, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{}, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    try std.testing.expect(outcome.isOk());
}

test "validate ignores empty string flag when non_empty is not set" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "permissive_like",
        .flags = &.{
            .{ .name = "note", .kind = .string },
        },
    };

    var result = try parse(allocator, &.{ "--note", "" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    try std.testing.expect(outcome.isOk());
}

test "validate empty_flag fires after empty_argument when both could match" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "argflag_like",
        .args = &.{
            .{ .name = "loop", .non_empty = true },
        },
        .flags = &.{
            .{ .name = "reason", .kind = .string, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{ "", "--reason", "" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_argument => |e| {
            try std.testing.expectEqualStrings("loop", e.arg_name);
        },
        else => try std.testing.expect(false),
    }
}

test "validate empty_flag fires when first non_empty flag with empty value walks declaration order" {
    const allocator = std.testing.allocator;

    const schema = Command{
        .name = "memory_curate_like",
        .flags = &.{
            .{ .name = "output", .short = 'o', .kind = .string, .non_empty = true },
            .{ .name = "to", .short = 't', .kind = .string, .non_empty = true },
            .{ .name = "session", .short = 's', .kind = .string, .non_empty = true },
        },
    };

    var result = try parse(allocator, &.{ "--output", "recap", "--to", "", "--session", "" }, &schema);
    defer result.deinit();

    const outcome = validate(&result);
    switch (outcome) {
        .empty_flag => |e| {
            try std.testing.expectEqualStrings("to", e.flag_name);
        },
        else => try std.testing.expect(false),
    }
}
