/// zig_command - Standalone CLI argument parsing, routing, and help generation.
///
/// Usage:
///   const cmd = @import("zig_command");
///
///   const schema = cmd.Command{
///       .name = "myapp",
///       .description = "Does useful things",
///       .args = &.{
///           .{ .name = "input", .required = true },
///           .{ .name = "output" },
///       },
///       .flags = &.{
///           .{ .name = "verbose", .short = 'v', .description = "Enable verbose output" },
///           .{ .name = "count", .short = 'n', .kind = .number },
///       },
///   };
///
///   const result = try cmd.parse(allocator, argv, &schema);
///   defer result.deinit();
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Command definition with args, flags, and subcommands.
pub const Command = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    args: ?[]const ArgDef = null,
    flags: ?[]const FlagDef = null,
    subcommands: ?[]const *const Command = null,
    examples: ?[]const []const u8 = null,
};

/// Positional argument definition.
pub const ArgDef = struct {
    name: []const u8,
    required: bool = true,
    variadic: bool = false,
    description: ?[]const u8 = null,
};

/// Flag definition.
pub const FlagDef = struct {
    name: []const u8,
    short: ?u8 = null,
    kind: FlagKind = .boolean,
    description: ?[]const u8 = null,
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
    rest: std.ArrayListUnmanaged([]const u8) = .empty,
    command: *const Command,
    parents: std.ArrayListUnmanaged(*const Command) = .empty,
    help_requested: bool = false,

    pub fn deinit(self: *ParseResult) void {
        self.args.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        self.rest.deinit(self.allocator);
        self.parents.deinit(self.allocator);
    }

    /// Get a flag value by name.
    pub fn getFlag(self: *const ParseResult, name: []const u8) ?FlagValue {
        return self.flags.get(name);
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
    OutOfMemory,
};

/// Parse command-line arguments against a schema.
pub fn parse(allocator: Allocator, argv: []const []const u8, schema: *const Command) ParseError!ParseResult {
    var result = ParseResult{
        .allocator = allocator,
        .command = schema,
    };
    errdefer result.deinit();

    var alias_map = std.AutoHashMapUnmanaged(u8, []const u8).empty;
    defer alias_map.deinit(allocator);

    if (schema.flags) |flags| {
        for (flags) |flag| {
            if (flag.short) |short| {
                alias_map.put(allocator, short, flag.name) catch return ParseError.OutOfMemory;
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

                for (sub_result.rest.items) |r| {
                    result.rest.append(allocator, r) catch return ParseError.OutOfMemory;
                }

                for (sub_result.parents.items) |p| {
                    result.parents.append(allocator, p) catch return ParseError.OutOfMemory;
                }

                result.help_requested = sub_result.help_requested;
                sub_result.deinit();
                return result;
            }
        }

        result.args.append(allocator, token) catch return ParseError.OutOfMemory;
        i += 1;
    }

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

    const flag_def = findFlag(schema, flag_name);
    const kind = if (flag_def) |f| f.kind else .boolean;

    if (flag_value) |val| {
        result.flags.put(allocator, flag_name, try coerceValue(val, kind)) catch return ParseError.OutOfMemory;
    } else if (kind == .boolean) {
        result.flags.put(allocator, flag_name, .{ .boolean = true }) catch return ParseError.OutOfMemory;
    } else {
        if (start + 1 < argv.len and !std.mem.startsWith(u8, argv[start + 1], "-")) {
            result.flags.put(allocator, flag_name, try coerceValue(argv[start + 1], kind)) catch return ParseError.OutOfMemory;
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
    alias_map: *std.AutoHashMapUnmanaged(u8, []const u8),
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

        const flag_name = alias_map.get(c) orelse &[_]u8{c};
        const flag_def = findFlag(schema, flag_name);
        const kind = if (flag_def) |f| f.kind else .boolean;
        const is_last = j == chars.len - 1;

        if (is_last and kind != .boolean) {
            if (start + 1 < argv.len and !std.mem.startsWith(u8, argv[start + 1], "-")) {
                result.flags.put(allocator, flag_name, try coerceValue(argv[start + 1], kind)) catch return ParseError.OutOfMemory;
                return start + 2;
            } else {
                return ParseError.MissingFlagValue;
            }
        } else {
            result.flags.put(allocator, flag_name, .{ .boolean = true }) catch return ParseError.OutOfMemory;
        }
    }

    return start + 1;
}

fn findFlag(schema: *const Command, name: []const u8) ?*const FlagDef {
    if (schema.flags) |flags| {
        for (flags) |*flag| {
            if (std.mem.eql(u8, flag.name, name)) {
                return flag;
            }
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

/// Validate parsed result against schema. Returns error message or null if valid.
pub fn validate(result: *const ParseResult) ?[]const u8 {
    const schema = result.command;

    if (schema.args) |arg_defs| {
        var required_count: usize = 0;

        for (arg_defs) |arg_def| {
            if (arg_def.required and !arg_def.variadic) {
                required_count += 1;
            }
        }

        if (result.args.items.len < required_count) {
            return "Missing required argument";
        }
    }
    return null;
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
            const s = if (flag.short) |short|
                try std.fmt.allocPrint(allocator, "  -{c}, --{s}", .{ short, flag.name })
            else
                try std.fmt.allocPrint(allocator, "      --{s}", .{flag.name});

            try parts.append(allocator, s);

            if (flag.description) |desc| {
                const name_len = flag.name.len + (if (flag.short != null) @as(usize, 6) else @as(usize, 8));
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
