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
///
/// For static Zig command trees, use `App(Tag, Handler)` to keep command
/// identity and routing attached to the schema:
///
///   const Tag = enum { root, feed, feed_tail };
///   const Handler = *const fn (*usize) void;
///   const app = cmd.App(Tag, Handler){
///       .root = .{
///           .tag = .root,
///           .name = "tool",
///           .handler = rootHandler,
///           .commands = &.{
///               .{
///                   .tag = .feed,
///                   .name = "feed",
///                   .handler = feedHandler,
///                   .commands = &.{
///                       .{ .tag = .feed_tail, .name = "tail", .handler = feedTailHandler },
///                   },
///               },
///           },
///       },
///   };
///
/// Typed handlers are intended to be thin adapters. Parent commands have their
/// own handlers and should not route child commands manually. The schema-only
/// `Command` API remains the right surface for dynamic schemas, including
/// lil-facing wrappers that construct command data at runtime.
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
    /// A trailing argument collects the rest of the command line as it is,
    /// the way `env` and `timeout` take a command: once it receives its first
    /// token, every later token is its, flags included, and every token after
    /// `--` is its too. It must be variadic and the last argument.
    trailing: bool = false,
};

/// The index of the command's trailing argument, when its last argument is
/// one.
fn trailingIndex(args: ?[]const ArgDef) ?usize {
    const defined = args orelse return null;
    if (defined.len == 0 or !defined[defined.len - 1].trailing) return null;
    return defined.len - 1;
}

/// The note help adds to a trailing argument's description.
const trailing_note = " (everything after the first word is passed through)";

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
    /// Never returned. Kept so existing exhaustive switches over
    /// `ParseError`, such as zsbpf's, keep compiling.
    InvalidFlag,
    MissingFlagValue,
    InvalidNumber,
    InvalidDefault,
    UnknownFlag,
    OutOfMemory,
};

/// What a diagnosed parse saw when it returned a `ParseError`, for a command
/// tree of `CommandType`. Each error fills the fields that apply to it and
/// leaves the rest at their defaults:
///
///   - `UnknownFlag`: `flag_name`, `short`, and `command`.
///   - `MissingFlagValue`: `flag_name`, `short`, `flag`, and `command`.
///   - `InvalidNumber`: `flag_name`, `short`, `value`, `flag`, and `command`.
///   - `InvalidDefault`: `flag` and `command`.
///
/// `flag_name` is the flag as the user spelled it, without leading dashes;
/// `short` is true when it was given with one dash, so `-x` has `flag_name`
/// "x" and `short` true. `command` is the command whose flags were being
/// parsed when the error happened.
pub fn ParseDiagnosticOf(comptime CommandType: type) type {
    return struct {
        flag_name: []const u8 = "",
        short: bool = false,
        value: []const u8 = "",
        flag: ?*const FlagDef = null,
        command: ?*const CommandType = null,
    };
}

/// The diagnostic for the schema-only `Command` API.
pub const ParseDiagnostic = ParseDiagnosticOf(Command);

/// Parse command-line arguments against a schema.
pub fn parse(allocator: Allocator, argv: []const []const u8, schema: *const Command) ParseError!ParseResult {
    var diagnostic: ParseDiagnostic = .{};

    return parseDiagnosed(allocator, argv, schema, &diagnostic);
}

/// Parse like `parse`, and on error describe what was seen in `diagnostic`.
pub fn parseDiagnosed(
    allocator: Allocator,
    argv: []const []const u8,
    schema: *const Command,
    diagnostic: *ParseDiagnostic,
) ParseError!ParseResult {
    return parseWithAncestors(allocator, argv, schema, &[_]*const Command{}, diagnostic);
}

/// Coerce a flag's text to its kind, recording the flag and text in
/// `diagnostic` when the text is not a valid number.
fn coerceFlagValue(
    value: []const u8,
    flag_def: *const FlagDef,
    flag_name: []const u8,
    short: bool,
    command: anytype,
    diagnostic: anytype,
) ParseError!FlagValue {
    return coerceValue(value, flag_def.kind) catch |err| {
        diagnostic.flag_name = flag_name;
        diagnostic.short = short;
        diagnostic.value = value;
        diagnostic.flag = flag_def;
        diagnostic.command = command;

        return err;
    };
}

/// Record a flag that needed a value and got none.
fn noteMissingValue(
    flag_def: *const FlagDef,
    flag_name: []const u8,
    short: bool,
    command: anytype,
    diagnostic: anytype,
) ParseError {
    diagnostic.flag_name = flag_name;
    diagnostic.short = short;
    diagnostic.flag = flag_def;
    diagnostic.command = command;

    return ParseError.MissingFlagValue;
}

/// Record a flag that no command in scope declares.
fn noteUnknownFlag(flag_name: []const u8, short: bool, command: anytype, diagnostic: anytype) ParseError {
    diagnostic.flag_name = flag_name;
    diagnostic.short = short;
    diagnostic.command = command;

    return ParseError.UnknownFlag;
}

/// Parse `argv` against `schema`, falling back to `ancestors` (the outer
/// commands, root first) when a flag is not defined on the current command. This
/// is what lets a global flag declared on the root command be accepted after a
/// subcommand token, not only before it. The public `parse` starts the walk with
/// no ancestors; each recursion into a subcommand appends the current command.
fn parseWithAncestors(
    allocator: Allocator,
    argv: []const []const u8,
    schema: *const Command,
    ancestors: []const *const Command,
    diagnostic: *ParseDiagnostic,
) ParseError!ParseResult {
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
            // A trailing argument takes what follows `--`; otherwise it is rest.
            const destination = if (trailingIndex(schema.args) != null) &result.args else &result.rest;
            i += 1;
            while (i < argv.len) : (i += 1) {
                destination.append(allocator, argv[i]) catch return ParseError.OutOfMemory;
            }
            break;
        }

        if (token.len > 2 and std.mem.startsWith(u8, token, "--")) {
            i = try parseLongFlag(argv, i, &result, schema, ancestors, allocator, diagnostic);
            continue;
        }

        if (token.len > 1 and token[0] == '-' and token[1] != '-') {
            i = try parseShortFlags(argv, i, &result, schema, &alias_map, ancestors, allocator, diagnostic);
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
                const child_ancestors = allocator.alloc(*const Command, ancestors.len + 1) catch return ParseError.OutOfMemory;
                defer allocator.free(child_ancestors);
                @memcpy(child_ancestors[0..ancestors.len], ancestors);
                child_ancestors[ancestors.len] = schema;
                var sub_result = try parseWithAncestors(allocator, argv[i + 1 ..], sub, child_ancestors, diagnostic);
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
                try applyDefaults(&result, schema, allocator, diagnostic);
                sub_result.deinit();
                return result;
            }
        }

        result.args.append(allocator, token) catch return ParseError.OutOfMemory;
        i += 1;
        if (trailingIndex(schema.args)) |trailing| {
            if (result.args.items.len > trailing) {
                while (i < argv.len) : (i += 1) {
                    result.args.append(allocator, argv[i]) catch return ParseError.OutOfMemory;
                }
                break;
            }
        }
    }

    try applyDefaults(&result, schema, allocator, diagnostic);
    return result;
}

fn parseLongFlag(
    argv: []const []const u8,
    start: usize,
    result: *ParseResult,
    schema: *const Command,
    ancestors: []const *const Command,
    allocator: Allocator,
    diagnostic: *ParseDiagnostic,
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

    const flag_def = findFlag(schema, flag_name) orelse findFlagInAncestors(ancestors, flag_name) orelse {
        return noteUnknownFlag(flag_name, false, schema, diagnostic);
    };

    const kind = flag_def.kind;

    if (flag_value) |val| {
        try putProvidedFlag(result, allocator, flag_def, try coerceFlagValue(val, flag_def, flag_name, false, schema, diagnostic));
    } else if (kind == .boolean) {
        try putProvidedFlag(result, allocator, flag_def, .{ .boolean = true });
    } else {
        if (start + 1 < argv.len and !std.mem.startsWith(u8, argv[start + 1], "-")) {
            try putProvidedFlag(result, allocator, flag_def, try coerceFlagValue(argv[start + 1], flag_def, flag_name, false, schema, diagnostic));
            return start + 2;
        } else {
            return noteMissingValue(flag_def, flag_name, false, schema, diagnostic);
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
    ancestors: []const *const Command,
    allocator: Allocator,
    diagnostic: *ParseDiagnostic,
) ParseError!usize {
    const token = argv[start];
    const chars = token[1..];

    var j: usize = 0;
    while (j < chars.len) : (j += 1) {
        const c = chars[j];
        const spelled = chars[j .. j + 1];

        if (c == 'h') {
            result.help_requested = true;
            continue;
        }

        const flag_def = alias_map.get(c) orelse findFlag(schema, spelled) orelse findShortFlagInAncestors(ancestors, c) orelse {
            return noteUnknownFlag(spelled, true, schema, diagnostic);
        };
        const kind = flag_def.kind;
        const is_last = j == chars.len - 1;

        if (is_last and kind != .boolean) {
            if (start + 1 < argv.len and !std.mem.startsWith(u8, argv[start + 1], "-")) {
                try putProvidedFlag(result, allocator, flag_def, try coerceFlagValue(argv[start + 1], flag_def, spelled, true, schema, diagnostic));
                return start + 2;
            } else {
                return noteMissingValue(flag_def, spelled, true, schema, diagnostic);
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

fn applyDefaults(
    result: *ParseResult,
    schema: *const Command,
    allocator: Allocator,
    diagnostic: *ParseDiagnostic,
) ParseError!void {
    if (schema.flags) |flags| {
        for (flags) |*flag| {
            const default_value = flag.default_value orelse continue;
            if (!flagValueMatchesKind(default_value, flag.kind)) {
                diagnostic.flag = flag;
                diagnostic.command = schema;

                return ParseError.InvalidDefault;
            }
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

/// Find a flag by name or alias in `ancestors` (the outer commands), searching
/// the nearest ancestor first so a closer command shadows a farther one. Returns
/// null when no ancestor declares the flag. This is the fallback that lets a
/// global flag declared on the root command be accepted after a subcommand token.
fn findFlagInAncestors(ancestors: []const *const Command, name: []const u8) ?*const FlagDef {
    var k = ancestors.len;
    while (k > 0) {
        k -= 1;
        if (findFlag(ancestors[k], name)) |flag| {
            return flag;
        }
    }
    return null;
}

/// Find a short flag by its `.short` byte (or a single-byte name/alias) in
/// `ancestors`, nearest first. The short-flag counterpart of
/// `findFlagInAncestors`: the current command's short flags resolve through an
/// alias map built from each flag's `.short`, which the long-flag name/alias
/// lookup does not cover, so an ancestor's short flag needs this dedicated walk.
fn findShortFlagInAncestors(ancestors: []const *const Command, c: u8) ?*const FlagDef {
    const name = [_]u8{c};
    var k = ancestors.len;
    while (k > 0) {
        k -= 1;
        const cmd = ancestors[k];
        if (cmd.flags) |flags| {
            for (flags) |*flag| {
                if (flag.short) |short| {
                    if (short == c) return flag;
                }
            }
        }
        if (findFlag(cmd, &name)) |flag| {
            return flag;
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
        /// The first required argument with no positional.
        arg_name: []const u8,
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

/// The name of the first required argument that `arg_count` positionals do
/// not reach. A required variadic tail counts as missing until it receives
/// one positional.
fn firstMissingArgName(arg_defs: []const ArgDef, arg_count: usize) []const u8 {
    for (arg_defs, 0..) |arg_def, i| {
        if (arg_def.required and i >= arg_count) {
            return arg_def.name;
        }
    }

    return arg_defs[arg_defs.len - 1].name;
}

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
            return .{ .missing_required = .{ .command = schema, .arg_name = firstMissingArgName(arg_defs, arg_count) } };
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
    const column = try helpColumn(allocator, command.args, command.flags, command.subcommands);

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
                    try appendPadding(allocator, &parts, arg.name.len + 2, column);
                    try parts.append(allocator, try allocator.dupe(u8, desc));
                    if (arg.trailing) try parts.append(allocator, try allocator.dupe(u8, trailing_note));
                }

                try parts.append(allocator, try allocator.dupe(u8, "\n"));
            }
        }
    }

    try parts.append(allocator, try allocator.dupe(u8, "\nFlags:\n"));

    try appendFlagHelp(allocator, &parts, command.flags, column);

    if (command.subcommands) |subcommands| {
        try parts.append(allocator, try allocator.dupe(u8, "\nCommands:\n"));

        for (subcommands) |sub| {
            const s = try std.fmt.allocPrint(allocator, "  {s}", .{sub.name});
            try parts.append(allocator, s);

            if (sub.description) |desc| {
                try appendPadding(allocator, &parts, sub.name.len + 2, column);
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

/// The column where descriptions start on one help screen: two spaces past
/// the widest argument, flag, or subcommand entry, and never before column
/// 20, so every section lines up and no entry runs into its description.
fn helpColumn(allocator: Allocator, args: ?[]const ArgDef, flags: ?[]const FlagDef, subcommands: anytype) !usize {
    var column: usize = 20;

    if (args) |defined| {
        for (defined) |arg| column = @max(column, arg.name.len + 4);
    }

    if (flags) |defined| {
        for (defined) |flag| {
            const spellings = try formatFlagSpellings(allocator, &flag);
            defer allocator.free(spellings);
            column = @max(column, spellings.len + 2);
        }
    }

    if (subcommands) |defined| {
        for (defined) |sub| column = @max(column, sub.name.len + 4);
    }

    return column;
}

/// Append the spaces that take an entry `written` columns wide to `column`.
fn appendPadding(allocator: Allocator, parts: *std.ArrayListUnmanaged([]const u8), written: usize, column: usize) !void {
    const pad = try allocator.alloc(u8, if (written + 2 <= column) column - written else 2);
    @memset(pad, ' ');
    try parts.append(allocator, pad);
}

/// Append one help line per flag, then the `-h, --help` line, each padded to
/// `description_column`. A flag's line shows its spellings, its value kind
/// when it takes a value, its description, and its default.
fn appendFlagHelp(
    allocator: Allocator,
    parts: *std.ArrayListUnmanaged([]const u8),
    flags: ?[]const FlagDef,
    description_column: usize,
) !void {
    if (flags) |defined| {
        for (defined) |flag| {
            const spellings = try formatFlagSpellings(allocator, &flag);
            try parts.append(allocator, spellings);

            const default_text = try formatFlagDefault(allocator, flag.default_value);
            defer if (default_text) |text| allocator.free(text);

            const description = flag.description orelse "";
            const separator = if (description.len > 0 and default_text != null)
                " "
            else
                "";

            if (description.len > 0 or default_text != null) {
                try appendPadding(allocator, parts, spellings.len, description_column);

                const line = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                    description,
                    separator,
                    default_text orelse "",
                });
                try parts.append(allocator, line);
            }

            try parts.append(allocator, try allocator.dupe(u8, "\n"));
        }
    }

    const help_spellings = "  -h, --help";
    try parts.append(allocator, try allocator.dupe(u8, help_spellings));
    try appendPadding(allocator, parts, help_spellings.len, description_column);
    try parts.append(allocator, try allocator.dupe(u8, "Show this help\n"));
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

    switch (flag.kind) {
        .boolean => {},
        .string => try buf.appendSlice(allocator, " <string>"),
        .number => try buf.appendSlice(allocator, " <number>"),
    }

    return buf.toOwnedSlice(allocator);
}

/// Render a flag default for help as "(default: value)", or null when the
/// flag has none. A boolean default of false is omitted, because an absent
/// boolean flag already means false.
fn formatFlagDefault(allocator: Allocator, default_value: ?FlagValue) !?[]const u8 {
    const value = default_value orelse return null;

    return switch (value) {
        .boolean => |b| if (b)
            try allocator.dupe(u8, "(default: true)")
        else
            null,
        .string => |s| try std.fmt.allocPrint(allocator, "(default: {s})", .{s}),
        .number => |n| try std.fmt.allocPrint(allocator, "(default: {d})", .{n}),
    };
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

pub fn App(comptime Tag: type, comptime Handler: type) type {
    return struct {
        const Self = @This();

        root: TypedCommand,

        pub const TypedCommand = struct {
            tag: Tag,
            name: []const u8,
            handler: Handler,
            description: ?[]const u8 = null,
            args: ?[]const ArgDef = null,
            flags: ?[]const FlagDef = null,
            commands: ?[]const TypedCommand = null,
            examples: ?[]const []const u8 = null,
            /// When true, the first positional token ends option and subcommand
            /// parsing for this command. Remaining tokens are collected in
            /// `ParseResult.rest` without interpreting flags or commands.
            stop_parsing_after_positional: bool = false,
            /// Prefixes of option tokens this command forwards instead of
            /// parsing. A dash-led token that starts with one of these
            /// prefixes is collected into `ParseResult.forwarded` in argv
            /// order rather than being read as flags, so a command can accept
            /// tool-style options such as Zig's `-Dname=value` without
            /// declaring every option name. Forwarded tokens are invisible to
            /// `validate`; the command's handler owns their meaning. Tokens
            /// after `--` keep going to `rest` unchanged.
            forwarded_argument_prefixes: ?[]const []const u8 = null,
        };

        pub const Command = TypedCommand;

        pub const ParseResult = struct {
            allocator: Allocator,
            args: std.ArrayListUnmanaged([]const u8) = .empty,
            flags: std.StringHashMapUnmanaged(FlagValue) = .empty,
            provided_flags: std.StringHashMapUnmanaged(void) = .empty,
            rest: std.ArrayListUnmanaged([]const u8) = .empty,
            /// Tokens matched by the command's `forwarded_argument_prefixes`,
            /// in argv order.
            forwarded: std.ArrayListUnmanaged([]const u8) = .empty,
            command: *const TypedCommand,
            parents: std.ArrayListUnmanaged(*const TypedCommand) = .empty,
            help_requested: bool = false,

            pub fn deinit(self: *@This()) void {
                self.args.deinit(self.allocator);
                self.flags.deinit(self.allocator);
                self.provided_flags.deinit(self.allocator);
                self.rest.deinit(self.allocator);
                self.forwarded.deinit(self.allocator);
                self.parents.deinit(self.allocator);
            }

            pub fn tag(self: *const @This()) Tag {
                return self.command.tag;
            }

            pub fn getFlag(self: *const @This(), name: []const u8) ?FlagValue {
                return self.flags.get(name);
            }

            pub fn wasProvided(self: *const @This(), name: []const u8) bool {
                return self.provided_flags.contains(name);
            }

            pub fn getBool(self: *const @This(), name: []const u8) ?bool {
                if (self.flags.get(name)) |val| {
                    return switch (val) {
                        .boolean => |b| b,
                        else => null,
                    };
                }
                return null;
            }

            pub fn getString(self: *const @This(), name: []const u8) ?[]const u8 {
                if (self.flags.get(name)) |val| {
                    return switch (val) {
                        .string => |s| s,
                        else => null,
                    };
                }
                return null;
            }

            pub fn getNumber(self: *const @This(), name: []const u8) ?i64 {
                if (self.flags.get(name)) |val| {
                    return switch (val) {
                        .number => |n| n,
                        else => null,
                    };
                }
                return null;
            }
        };

        pub const ValidationResult = union(enum) {
            ok,
            missing_required: struct {
                command: *const TypedCommand,
                arg_name: []const u8,
            },
            unknown_subcommand: struct {
                command: *const TypedCommand,
                token: []const u8,
            },
            unexpected_extra: struct {
                command: *const TypedCommand,
                token: []const u8,
            },
            empty_argument: struct {
                command: *const TypedCommand,
                arg_name: []const u8,
                position: usize,
            },
            empty_flag: struct {
                command: *const TypedCommand,
                flag_name: []const u8,
            },

            pub fn isOk(self: @This()) bool {
                return self == .ok;
            }
        };

        /// The diagnostic for this app's typed command tree.
        pub const ParseDiagnostic = ParseDiagnosticOf(TypedCommand);

        pub fn parse(self: *const Self, allocator: Allocator, argv: []const []const u8) ParseError!Self.ParseResult {
            var diagnostic: Self.ParseDiagnostic = .{};

            return parseCommandWithAncestors(allocator, argv, &self.root, &.{}, &diagnostic);
        }

        /// Parse like `parse`, and on error describe what was seen in `diagnostic`.
        pub fn parseDiagnosed(
            self: *const Self,
            allocator: Allocator,
            argv: []const []const u8,
            diagnostic: *Self.ParseDiagnostic,
        ) ParseError!Self.ParseResult {
            return parseCommandWithAncestors(allocator, argv, &self.root, &.{}, diagnostic);
        }

        pub fn validate(result: *const Self.ParseResult) Self.ValidationResult {
            if (result.help_requested) return .ok;

            const schema = result.command;
            const arg_count = result.args.items.len;

            if (schema.args == null) {
                if (arg_count > 0) {
                    if (schema.commands != null) {
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
                var has_variadic_tail = false;
                for (arg_defs, 0..) |arg_def, i| {
                    const is_tail_variadic = arg_def.variadic and i == arg_defs.len - 1;
                    if (arg_def.required and !is_tail_variadic) required_count += 1;
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
                    return .{ .missing_required = .{ .command = schema, .arg_name = firstMissingArgName(arg_defs, arg_count) } };
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

        pub fn formatHelp(self: *const Self, allocator: Allocator, command: *const TypedCommand, parents: []const *const TypedCommand) ![]const u8 {
            _ = self;
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            defer {
                for (parts.items) |p| allocator.free(p);
                parts.deinit(allocator);
            }
            const column = try helpColumn(allocator, command.args, command.flags, command.commands);

            try parts.append(allocator, try allocator.dupe(u8, "Usage: "));
            for (parents) |p| {
                try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s} ", .{p.name}));
            }
            try parts.append(allocator, try allocator.dupe(u8, command.name));

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

            if (command.commands != null) {
                try parts.append(allocator, try allocator.dupe(u8, " [command]"));
            }

            try parts.append(allocator, try allocator.dupe(u8, "\n"));

            if (command.description) |desc| {
                try parts.append(allocator, try std.fmt.allocPrint(allocator, "\n{s}\n", .{desc}));
            }

            if (command.args) |args| {
                if (args.len > 0) {
                    try parts.append(allocator, try allocator.dupe(u8, "\nArguments:\n"));
                    for (args) |arg| {
                        try parts.append(allocator, try std.fmt.allocPrint(allocator, "  {s}", .{arg.name}));
                        if (arg.description) |desc| {
                            try appendPadding(allocator, &parts, arg.name.len + 2, column);
                            try parts.append(allocator, try allocator.dupe(u8, desc));
                            if (arg.trailing) try parts.append(allocator, try allocator.dupe(u8, trailing_note));
                        }
                        try parts.append(allocator, try allocator.dupe(u8, "\n"));
                    }
                }
            }

            try parts.append(allocator, try allocator.dupe(u8, "\nFlags:\n"));
            try appendFlagHelp(allocator, &parts, command.flags, column);

            if (command.commands) |commands| {
                try parts.append(allocator, try allocator.dupe(u8, "\nCommands:\n"));
                for (commands) |*sub| {
                    try parts.append(allocator, try std.fmt.allocPrint(allocator, "  {s}", .{sub.name}));

                    if (sub.description) |desc| {
                        try appendPadding(allocator, &parts, sub.name.len + 2, column);
                        try parts.append(allocator, try allocator.dupe(u8, desc));
                    }

                    try parts.append(allocator, try allocator.dupe(u8, "\n"));
                }
            }

            if (command.examples) |examples| {
                try parts.append(allocator, try allocator.dupe(u8, "\nExamples:\n"));
                for (examples) |example| {
                    try parts.append(allocator, try std.fmt.allocPrint(allocator, "  {s}\n", .{example}));
                }
            }

            var total_len: usize = 0;
            for (parts.items) |p| total_len += p.len;

            const result = try allocator.alloc(u8, total_len);
            var offset: usize = 0;
            for (parts.items) |p| {
                @memcpy(result[offset..][0..p.len], p);
                offset += p.len;
            }
            return result;
        }

        pub fn dispatch(_: *const Self, result: *const Self.ParseResult, args: anytype) HandlerReturn() {
            return @call(.auto, result.command.handler, args);
        }

        fn HandlerReturn() type {
            const info = @typeInfo(Handler);
            const fn_type = switch (info) {
                .pointer => |ptr| ptr.child,
                .@"fn" => Handler,
                else => @compileError("zig_command.App Handler must be a function or function pointer"),
            };
            return @typeInfo(fn_type).@"fn".return_type orelse void;
        }

        fn parseCommandWithAncestors(
            allocator: Allocator,
            argv: []const []const u8,
            schema: *const TypedCommand,
            ancestors: []const *const TypedCommand,
            diagnostic: *Self.ParseDiagnostic,
        ) ParseError!Self.ParseResult {
            var result = Self.ParseResult{
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
                    // A trailing argument takes what follows `--`; otherwise it is rest.
                    const destination = if (trailingIndex(schema.args) != null) &result.args else &result.rest;
                    i += 1;
                    while (i < argv.len) : (i += 1) {
                        destination.append(allocator, argv[i]) catch return ParseError.OutOfMemory;
                    }
                    break;
                }

                if (token.len > 1 and token[0] == '-' and matchesForwardedPrefix(schema, token)) {
                    result.forwarded.append(allocator, token) catch return ParseError.OutOfMemory;
                    i += 1;
                    continue;
                }

                if (token.len > 2 and std.mem.startsWith(u8, token, "--")) {
                    i = try parseTypedLongFlag(argv, i, &result, schema, ancestors, allocator, diagnostic);
                    continue;
                }

                if (token.len > 1 and token[0] == '-' and token[1] != '-') {
                    i = try parseTypedShortFlags(argv, i, &result, schema, &alias_map, ancestors, allocator, diagnostic);
                    continue;
                }

                if (schema.commands) |commands| {
                    var found_sub: ?*const TypedCommand = null;
                    for (commands) |*sub| {
                        if (std.mem.eql(u8, token, sub.name)) {
                            found_sub = sub;
                            break;
                        }
                    }

                    if (found_sub) |sub| {
                        result.parents.append(allocator, schema) catch return ParseError.OutOfMemory;
                        const child_ancestors = allocator.alloc(*const TypedCommand, ancestors.len + 1) catch return ParseError.OutOfMemory;
                        defer allocator.free(child_ancestors);
                        @memcpy(child_ancestors[0..ancestors.len], ancestors);
                        child_ancestors[ancestors.len] = schema;

                        var sub_result = try parseCommandWithAncestors(allocator, argv[i + 1 ..], sub, child_ancestors, diagnostic);
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

                        for (sub_result.forwarded.items) |forwarded_token| {
                            result.forwarded.append(allocator, forwarded_token) catch return ParseError.OutOfMemory;
                        }

                        for (sub_result.parents.items) |p| {
                            result.parents.append(allocator, p) catch return ParseError.OutOfMemory;
                        }

                        result.help_requested = sub_result.help_requested;
                        try applyTypedDefaults(&result, schema, allocator, diagnostic);
                        sub_result.deinit();
                        return result;
                    }
                }

                result.args.append(allocator, token) catch return ParseError.OutOfMemory;
                i += 1;
                if (trailingIndex(schema.args)) |trailing| {
                    if (result.args.items.len > trailing) {
                        while (i < argv.len) : (i += 1) {
                            result.args.append(allocator, argv[i]) catch return ParseError.OutOfMemory;
                        }
                        break;
                    }
                }
                if (schema.stop_parsing_after_positional) {
                    while (i < argv.len) : (i += 1) {
                        result.rest.append(allocator, argv[i]) catch return ParseError.OutOfMemory;
                    }
                    break;
                }
            }

            try applyTypedDefaults(&result, schema, allocator, diagnostic);
            return result;
        }

        fn matchesForwardedPrefix(schema: *const TypedCommand, token: []const u8) bool {
            const prefixes = schema.forwarded_argument_prefixes orelse return false;
            for (prefixes) |prefix| {
                if (std.mem.startsWith(u8, token, prefix)) return true;
            }
            return false;
        }

        fn parseTypedLongFlag(
            argv: []const []const u8,
            start: usize,
            result: *Self.ParseResult,
            schema: *const TypedCommand,
            ancestors: []const *const TypedCommand,
            allocator: Allocator,
            diagnostic: *Self.ParseDiagnostic,
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

            const flag_def = findTypedFlag(schema, flag_name) orelse findTypedFlagInAncestors(ancestors, flag_name) orelse {
                return noteUnknownFlag(flag_name, false, schema, diagnostic);
            };
            const kind = flag_def.kind;

            if (flag_value) |val| {
                try putTypedProvidedFlag(result, allocator, flag_def, try coerceFlagValue(val, flag_def, flag_name, false, schema, diagnostic));
            } else if (kind == .boolean) {
                try putTypedProvidedFlag(result, allocator, flag_def, .{ .boolean = true });
            } else {
                if (start + 1 < argv.len and !std.mem.startsWith(u8, argv[start + 1], "-")) {
                    try putTypedProvidedFlag(result, allocator, flag_def, try coerceFlagValue(argv[start + 1], flag_def, flag_name, false, schema, diagnostic));
                    return start + 2;
                }
                return noteMissingValue(flag_def, flag_name, false, schema, diagnostic);
            }

            return start + 1;
        }

        fn parseTypedShortFlags(
            argv: []const []const u8,
            start: usize,
            result: *Self.ParseResult,
            schema: *const TypedCommand,
            alias_map: *std.AutoHashMapUnmanaged(u8, *const FlagDef),
            ancestors: []const *const TypedCommand,
            allocator: Allocator,
            diagnostic: *Self.ParseDiagnostic,
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

                const spelled = chars[j .. j + 1];
                const flag_def = alias_map.get(c) orelse findTypedFlag(schema, spelled) orelse findTypedShortFlagInAncestors(ancestors, c) orelse {
                    return noteUnknownFlag(spelled, true, schema, diagnostic);
                };
                const kind = flag_def.kind;
                const is_last = j == chars.len - 1;

                if (is_last and kind != .boolean) {
                    if (start + 1 < argv.len and !std.mem.startsWith(u8, argv[start + 1], "-")) {
                        try putTypedProvidedFlag(result, allocator, flag_def, try coerceFlagValue(argv[start + 1], flag_def, spelled, true, schema, diagnostic));
                        return start + 2;
                    }
                    return noteMissingValue(flag_def, spelled, true, schema, diagnostic);
                }

                try putTypedProvidedFlag(result, allocator, flag_def, .{ .boolean = true });
            }

            return start + 1;
        }

        fn putTypedProvidedFlag(result: *Self.ParseResult, allocator: Allocator, flag_def: *const FlagDef, value: FlagValue) ParseError!void {
            const key = flag_def.key();
            result.flags.put(allocator, key, value) catch return ParseError.OutOfMemory;
            result.provided_flags.put(allocator, key, {}) catch return ParseError.OutOfMemory;
        }

        fn applyTypedDefaults(result: *Self.ParseResult, schema: *const TypedCommand, allocator: Allocator, diagnostic: *Self.ParseDiagnostic) ParseError!void {
            if (schema.flags) |flags| {
                for (flags) |*flag| {
                    const default_value = flag.default_value orelse continue;
                    if (!flagValueMatchesKind(default_value, flag.kind)) {
                        diagnostic.flag = flag;
                        diagnostic.command = schema;

                        return ParseError.InvalidDefault;
                    }
                    if (result.flags.contains(flag.key())) continue;
                    result.flags.put(allocator, flag.key(), default_value) catch return ParseError.OutOfMemory;
                }
            }
        }

        fn findTypedFlag(schema: *const TypedCommand, name: []const u8) ?*const FlagDef {
            if (schema.flags) |flags| {
                for (flags) |*flag| {
                    if (std.mem.eql(u8, flag.name, name)) return flag;
                    if (flag.aliases) |aliases| {
                        for (aliases) |alias| {
                            if (std.mem.eql(u8, alias, name)) return flag;
                        }
                    }
                }
            }
            return null;
        }

        fn findTypedFlagInAncestors(ancestors: []const *const TypedCommand, name: []const u8) ?*const FlagDef {
            var k = ancestors.len;
            while (k > 0) {
                k -= 1;
                if (findTypedFlag(ancestors[k], name)) |flag| {
                    return flag;
                }
            }

            return null;
        }

        fn findTypedShortFlagInAncestors(ancestors: []const *const TypedCommand, c: u8) ?*const FlagDef {
            const name = [_]u8{c};
            var k = ancestors.len;
            while (k > 0) {
                k -= 1;
                const command = ancestors[k];
                if (command.flags) |flags| {
                    for (flags) |*flag| {
                        if (flag.short) |short| {
                            if (short == c) return flag;
                        }
                    }
                }
                if (findTypedFlag(command, &name)) |flag| {
                    return flag;
                }
            }

            return null;
        }
    };
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

test "parse accepts a root long flag after a subcommand token" {
    const allocator = std.testing.allocator;

    const sub = Command{ .name = "list" };

    const schema = Command{
        .name = "looplab",
        .flags = &.{
            .{ .name = "workspace", .kind = .string },
        },
        .subcommands = &.{&sub},
    };

    var after = try parse(allocator, &.{ "list", "--workspace", "/ws" }, &schema);
    defer after.deinit();
    try std.testing.expectEqualStrings("list", after.command.name);
    try std.testing.expectEqualStrings("/ws", after.getString("workspace").?);

    var before = try parse(allocator, &.{ "--workspace", "/ws", "list" }, &schema);
    defer before.deinit();
    try std.testing.expectEqualStrings("list", before.command.name);
    try std.testing.expectEqualStrings("/ws", before.getString("workspace").?);
}

test "parse accepts a root short flag after a subcommand token" {
    const allocator = std.testing.allocator;

    const sub = Command{ .name = "go" };

    const schema = Command{
        .name = "tool",
        .flags = &.{
            .{ .name = "verbose", .short = 'v', .kind = .boolean },
        },
        .subcommands = &.{&sub},
    };

    var result = try parse(allocator, &.{ "go", "-v" }, &schema);
    defer result.deinit();
    try std.testing.expectEqualStrings("go", result.command.name);
    try std.testing.expect(result.getBool("verbose").?);
}

test "parse still rejects a flag unknown to both subcommand and ancestors" {
    const allocator = std.testing.allocator;

    const sub = Command{ .name = "list" };

    const schema = Command{
        .name = "looplab",
        .flags = &.{
            .{ .name = "workspace", .kind = .string },
        },
        .subcommands = &.{&sub},
    };

    try std.testing.expectError(ParseError.UnknownFlag, parse(allocator, &.{ "list", "--nope" }, &schema));
}

test "a subcommand flag shadows a root flag of the same name" {
    const allocator = std.testing.allocator;

    const sub = Command{
        .name = "child",
        .flags = &.{
            .{ .name = "mode", .kind = .string },
        },
    };

    const schema = Command{
        .name = "root",
        .flags = &.{
            .{ .name = "mode", .kind = .string },
        },
        .subcommands = &.{&sub},
    };

    var result = try parse(allocator, &.{ "child", "--mode", "leaf" }, &schema);
    defer result.deinit();
    try std.testing.expectEqualStrings("leaf", result.getString("mode").?);
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
        .missing_required => |e| {
            try std.testing.expectEqual(&schema, e.command);
            try std.testing.expectEqualStrings("input", e.arg_name);
        },
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
        .missing_required => |e| try std.testing.expectEqualStrings("first", e.arg_name),
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
        .missing_required => |e| try std.testing.expectEqualStrings("message", e.arg_name),
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
        .missing_required => |e| try std.testing.expectEqualStrings("message", e.arg_name),
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
        .missing_required => |e| try std.testing.expectEqualStrings("message", e.arg_name),
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

const TypedTestTag = enum {
    root,
    parent,
    leaf,
    first_dup,
    second_dup,
};

const typed_test_app = App(TypedTestTag, *const fn (*usize) void);

fn typedRoot(out: *usize) void {
    out.* = 1;
}

fn typedParent(out: *usize) void {
    out.* = 2;
}

fn typedLeaf(out: *usize) void {
    out.* = 3;
}

fn typedHandler(_: *usize) void {}

test "typed app parses root parent and leaf commands to distinct tags" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .commands = &.{
                .{
                    .tag = .parent,
                    .name = "parent",
                    .handler = typedParent,
                    .commands = &.{
                        .{
                            .tag = .leaf,
                            .name = "leaf",
                            .handler = typedLeaf,
                            .args = &.{.{ .name = "value", .non_empty = true }},
                            .flags = &.{.{ .name = "count", .aliases = &.{"n"}, .kind = .number }},
                        },
                    },
                },
            },
        },
    };

    var root_result = try app.parse(std.testing.allocator, &.{});
    defer root_result.deinit();
    try std.testing.expectEqual(TypedTestTag.root, root_result.tag());
    try std.testing.expectEqual(@as(usize, 0), root_result.parents.items.len);

    var parent_result = try app.parse(std.testing.allocator, &.{"parent"});
    defer parent_result.deinit();
    try std.testing.expectEqual(TypedTestTag.parent, parent_result.tag());
    try std.testing.expectEqual(@as(usize, 1), parent_result.parents.items.len);
    try std.testing.expectEqual(TypedTestTag.root, parent_result.parents.items[0].tag);

    var leaf_result = try app.parse(std.testing.allocator, &.{ "parent", "leaf", "--count", "3", "x" });
    defer leaf_result.deinit();
    try std.testing.expectEqual(TypedTestTag.leaf, leaf_result.tag());
    try std.testing.expectEqual(@as(usize, 2), leaf_result.parents.items.len);
    try std.testing.expectEqual(TypedTestTag.root, leaf_result.parents.items[0].tag);
    try std.testing.expectEqual(TypedTestTag.parent, leaf_result.parents.items[1].tag);
    try std.testing.expectEqualStrings("x", leaf_result.args.items[0]);
    try std.testing.expectEqual(@as(i64, 3), leaf_result.getNumber("count").?);
    try std.testing.expect(typed_test_app.validate(&leaf_result).isOk());

    var routed: usize = 0;
    app.dispatch(&leaf_result, .{&routed});
    try std.testing.expectEqual(@as(usize, 3), routed);
}

test "typed app accepts root flags after subcommand tokens" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .flags = &.{
                .{ .name = "workspace", .kind = .string },
                .{ .name = "verbose", .short = 'v', .kind = .boolean },
            },
            .commands = &.{
                .{ .tag = .leaf, .name = "list", .handler = typedLeaf },
            },
        },
    };

    var long_result = try app.parse(std.testing.allocator, &.{ "list", "--workspace", "/ws" });
    defer long_result.deinit();
    try std.testing.expectEqual(TypedTestTag.leaf, long_result.tag());
    try std.testing.expectEqualStrings("/ws", long_result.getString("workspace").?);

    var short_result = try app.parse(std.testing.allocator, &.{ "list", "-v" });
    defer short_result.deinit();
    try std.testing.expectEqual(TypedTestTag.leaf, short_result.tag());
    try std.testing.expect(short_result.getBool("verbose").?);
}

test "typed app can stop parsing after first positional token" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .args = &.{.{ .name = "script", .required = false, .variadic = true }},
            .flags = &.{.{ .name = "version", .kind = .boolean }},
            .stop_parsing_after_positional = true,
        },
    };

    var result = try app.parse(std.testing.allocator, &.{ "script.relay", "--version", "x" });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.args.items.len);
    try std.testing.expectEqualStrings("script.relay", result.args.items[0]);
    try std.testing.expectEqual(@as(usize, 2), result.rest.items.len);
    try std.testing.expectEqualStrings("--version", result.rest.items[0]);
    try std.testing.expectEqualStrings("x", result.rest.items[1]);
    try std.testing.expect(!result.wasProvided("version"));
    try std.testing.expect(result.getBool("version") == null);
}

test "typed app keeps explicit separator in rest after first positional token" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .args = &.{.{ .name = "script", .required = false, .variadic = true }},
            .flags = &.{.{ .name = "version", .kind = .boolean }},
            .stop_parsing_after_positional = true,
        },
    };

    var result = try app.parse(std.testing.allocator, &.{ "script.relay", "--", "pods", "--help" });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.args.items.len);
    try std.testing.expectEqualStrings("script.relay", result.args.items[0]);
    try std.testing.expectEqual(@as(usize, 3), result.rest.items.len);
    try std.testing.expectEqualStrings("--", result.rest.items[0]);
    try std.testing.expectEqualStrings("pods", result.rest.items[1]);
    try std.testing.expectEqualStrings("--help", result.rest.items[2]);
    try std.testing.expect(!result.wasProvided("version"));
    try std.testing.expect(result.getBool("version") == null);
}

test "typed app rejects flags unknown to subcommand and ancestors" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .commands = &.{
                .{ .tag = .leaf, .name = "list", .handler = typedLeaf },
            },
        },
    };

    try std.testing.expectError(ParseError.UnknownFlag, app.parse(std.testing.allocator, &.{ "list", "--nope" }));
    try std.testing.expectError(ParseError.UnknownFlag, app.parse(std.testing.allocator, &.{ "list", "-z" }));
}

test "typed app forwards declared option prefixes instead of parsing them as flags" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .commands = &.{
                .{
                    .tag = .leaf,
                    .name = "build",
                    .handler = typedLeaf,
                    .args = &.{.{ .name = "step", .required = false, .non_empty = true }},
                    .flags = &.{.{ .name = "zig", .kind = .string }},
                    .forwarded_argument_prefixes = &.{"-D"},
                },
            },
        },
    };

    var result = try app.parse(std.testing.allocator, &.{
        "build",
        "--zig",
        "/toolchain/zig",
        "-Dtarget=x86_64-linux-musl",
        "install",
        "-Doptimize=ReleaseSafe",
        "--",
        "tail-arg",
    });
    defer result.deinit();

    try std.testing.expectEqual(TypedTestTag.leaf, result.tag());
    try std.testing.expectEqualStrings("/toolchain/zig", result.getString("zig").?);
    try std.testing.expectEqual(@as(usize, 2), result.forwarded.items.len);
    try std.testing.expectEqualStrings("-Dtarget=x86_64-linux-musl", result.forwarded.items[0]);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseSafe", result.forwarded.items[1]);
    try std.testing.expectEqual(@as(usize, 1), result.args.items.len);
    try std.testing.expectEqualStrings("install", result.args.items[0]);
    try std.testing.expectEqual(@as(usize, 1), result.rest.items.len);
    try std.testing.expectEqualStrings("tail-arg", result.rest.items[0]);
    try std.testing.expect(typed_test_app.validate(&result).isOk());
}

test "typed app without forwarded prefixes keeps rejecting dash-led option tokens" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .commands = &.{
                .{
                    .tag = .leaf,
                    .name = "build",
                    .handler = typedLeaf,
                    .flags = &.{.{ .name = "zig", .kind = .string }},
                },
            },
        },
    };

    try std.testing.expectError(ParseError.UnknownFlag, app.parse(std.testing.allocator, &.{ "build", "-Dtarget=x86_64-linux-musl" }));
}

test "typed app help bypasses required positional validation" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .commands = &.{
                .{
                    .tag = .leaf,
                    .name = "show",
                    .handler = typedLeaf,
                    .args = &.{.{ .name = "target", .required = true }},
                },
            },
        },
    };

    var result = try app.parse(std.testing.allocator, &.{ "show", "--help" });
    defer result.deinit();

    try std.testing.expect(result.help_requested);
    try std.testing.expect(typed_test_app.validate(&result).isOk());
}

test "typed app help formatting includes parent and leaf commands" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .description = "Typed app",
            .commands = &.{
                .{
                    .tag = .parent,
                    .name = "parent",
                    .handler = typedParent,
                    .description = "Parent command",
                },
            },
        },
    };

    var result = try app.parse(std.testing.allocator, &.{"--help"});
    defer result.deinit();
    const help = try app.formatHelp(std.testing.allocator, result.command, result.parents.items);
    defer std.testing.allocator.free(help);

    try std.testing.expect(result.help_requested);
    try std.testing.expect(std.mem.indexOf(u8, help, "Usage: app [command]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "parent") != null);
}

test "typed app preserves first-match sibling command behavior" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .commands = &.{
                .{ .tag = .first_dup, .name = "dup", .handler = typedHandler },
                .{ .tag = .second_dup, .name = "dup", .handler = typedHandler },
            },
        },
    };

    var result = try app.parse(std.testing.allocator, &.{"dup"});
    defer result.deinit();

    try std.testing.expectEqual(TypedTestTag.first_dup, result.tag());
}

const diagnostic_test_schema = Command{
    .name = "mail",
    .flags = &.{
        .{ .name = "from", .kind = .string, .aliases = &.{"f"} },
        .{ .name = "limit", .kind = .number, .default_value = .{ .number = 20 } },
        .{ .name = "verbose", .aliases = &.{"v"} },
    },
};

test "parseDiagnosed names an unknown long flag and its command" {
    var diagnostic: ParseDiagnostic = .{};

    try std.testing.expectError(
        ParseError.UnknownFlag,
        parseDiagnosed(std.testing.allocator, &.{"--subject=hi"}, &diagnostic_test_schema, &diagnostic),
    );

    try std.testing.expectEqualStrings("subject", diagnostic.flag_name);
    try std.testing.expect(!diagnostic.short);
    try std.testing.expectEqual(&diagnostic_test_schema, diagnostic.command.?);
}

test "parseDiagnosed names an unknown short flag inside a group" {
    var diagnostic: ParseDiagnostic = .{};

    try std.testing.expectError(
        ParseError.UnknownFlag,
        parseDiagnosed(std.testing.allocator, &.{"-vx"}, &diagnostic_test_schema, &diagnostic),
    );

    try std.testing.expectEqualStrings("x", diagnostic.flag_name);
    try std.testing.expect(diagnostic.short);
}

test "parseDiagnosed names a flag missing its value" {
    var diagnostic: ParseDiagnostic = .{};

    try std.testing.expectError(
        ParseError.MissingFlagValue,
        parseDiagnosed(std.testing.allocator, &.{"-f"}, &diagnostic_test_schema, &diagnostic),
    );

    try std.testing.expectEqualStrings("f", diagnostic.flag_name);
    try std.testing.expect(diagnostic.short);
    try std.testing.expectEqualStrings("from", diagnostic.flag.?.name);
}

test "parseDiagnosed names a flag given a non-number" {
    var diagnostic: ParseDiagnostic = .{};

    try std.testing.expectError(
        ParseError.InvalidNumber,
        parseDiagnosed(std.testing.allocator, &.{ "--limit", "abc" }, &diagnostic_test_schema, &diagnostic),
    );

    try std.testing.expectEqualStrings("limit", diagnostic.flag_name);
    try std.testing.expectEqualStrings("abc", diagnostic.value);
    try std.testing.expectEqualStrings("limit", diagnostic.flag.?.name);
}

test "parseDiagnosed names a flag with a mismatched default" {
    const schema = Command{
        .name = "bad",
        .flags = &.{
            .{ .name = "count", .kind = .number, .default_value = .{ .string = "three" } },
        },
    };
    var diagnostic: ParseDiagnostic = .{};

    try std.testing.expectError(
        ParseError.InvalidDefault,
        parseDiagnosed(std.testing.allocator, &.{}, &schema, &diagnostic),
    );

    try std.testing.expectEqualStrings("count", diagnostic.flag.?.name);
    try std.testing.expectEqual(&schema, diagnostic.command.?);
}

test "parseDiagnosed names the subcommand whose flags were parsed" {
    const send = Command{
        .name = "send",
        .flags = &.{
            .{ .name = "from", .kind = .string },
        },
    };
    const schema = Command{
        .name = "mail",
        .subcommands = &.{&send},
    };
    var diagnostic: ParseDiagnostic = .{};

    try std.testing.expectError(
        ParseError.UnknownFlag,
        parseDiagnosed(std.testing.allocator, &.{ "send", "--subject" }, &schema, &diagnostic),
    );

    try std.testing.expectEqualStrings("subject", diagnostic.flag_name);
    try std.testing.expectEqual(&send, diagnostic.command.?);
}

test "typed app parseDiagnosed names an unknown flag" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .commands = &.{
                .{ .tag = .leaf, .name = "list", .handler = typedLeaf },
            },
        },
    };
    var diagnostic: typed_test_app.ParseDiagnostic = .{};

    try std.testing.expectError(
        ParseError.UnknownFlag,
        app.parseDiagnosed(std.testing.allocator, &.{ "list", "-z" }, &diagnostic),
    );

    try std.testing.expectEqualStrings("z", diagnostic.flag_name);
    try std.testing.expect(diagnostic.short);
    try std.testing.expectEqualStrings("list", diagnostic.command.?.name);
}

test "format help shows value kinds and defaults" {
    const help = try formatHelp(std.testing.allocator, &diagnostic_test_schema, &.{});
    defer std.testing.allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "--from <string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--limit <number>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "(default: 20)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--verbose <") == null);
}

test "format help aligns the help flag with other flags" {
    const schema = Command{
        .name = "tool",
        .flags = &.{
            .{ .name = "quiet", .description = "Say less" },
        },
    };
    const help = try formatHelp(std.testing.allocator, &schema, &.{});
    defer std.testing.allocator.free(help);

    const quiet_line = "  --quiet           Say less\n";
    const help_line = "  -h, --help        Show this help\n";

    try std.testing.expect(std.mem.indexOf(u8, help, quiet_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, help, help_line) != null);
}

test "format help moves every description past the widest entry" {
    const schema = Command{
        .name = "tool",
        .args = &.{
            .{ .name = "scripts", .description = "Scripts to link" },
        },
        .flags = &.{
            .{ .name = "quiet", .description = "Say less" },
            .{ .name = "bin-dir", .kind = .string, .description = "Where links go" },
            .{ .name = "tool-call", .kind = .string, .description = "Run from JSON" },
        },
    };
    const help = try formatHelp(std.testing.allocator, &schema, &.{});
    defer std.testing.allocator.free(help);

    // "  --tool-call <string>" is 22 wide, so descriptions start at column 24.
    const expected_lines = [_][]const u8{
        "  scripts               Scripts to link\n",
        "  --quiet               Say less\n",
        "  --bin-dir <string>    Where links go\n",
        "  --tool-call <string>  Run from JSON\n",
        "  -h, --help            Show this help\n",
    };

    for (expected_lines) |line| {
        if (std.mem.indexOf(u8, help, line) == null) {
            std.debug.print("missing line: {s}in help:\n{s}\n", .{ line, help });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectTokens(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

const trailing_schema = Command{
    .name = "run",
    .args = &.{.{ .name = "words", .variadic = true, .trailing = true }},
    .flags = &.{.{ .name = "timeout", .kind = .number, .default_value = .{ .number = 60 } }},
};

test "a trailing argument takes flags after its first word" {
    var result = try parse(std.testing.allocator, &.{ "--timeout", "5", "ls", "-la", "--timeout", "9" }, &trailing_schema);
    defer result.deinit();

    try expectTokens(&.{ "ls", "-la", "--timeout", "9" }, result.args.items);
    try std.testing.expectEqual(@as(i64, 5), result.flags.get("timeout").?.number);
    try std.testing.expectEqual(@as(usize, 0), result.rest.items.len);
}

test "a trailing argument takes the tokens after --" {
    var result = try parse(std.testing.allocator, &.{ "--", "-x", "y" }, &trailing_schema);
    defer result.deinit();

    try expectTokens(&.{ "-x", "y" }, result.args.items);
    try std.testing.expectEqual(@as(usize, 0), result.rest.items.len);
    try std.testing.expect(validate(&result) == .ok);
}

test "typed app trailing argument takes flags and tokens after --" {
    const app = typed_test_app{
        .root = .{
            .tag = .root,
            .name = "app",
            .handler = typedRoot,
            .args = &.{.{ .name = "words", .variadic = true, .trailing = true }},
            .flags = &.{.{ .name = "version", .kind = .boolean }},
        },
    };

    var flags_after = try app.parse(std.testing.allocator, &.{ "--version", "grep", "--version", "-r" });
    defer flags_after.deinit();
    try expectTokens(&.{ "grep", "--version", "-r" }, flags_after.args.items);
    try std.testing.expect(flags_after.getBool("version").?);

    var after_separator = try app.parse(std.testing.allocator, &.{ "--", "-x" });
    defer after_separator.deinit();
    try expectTokens(&.{"-x"}, after_separator.args.items);
    try std.testing.expectEqual(@as(usize, 0), after_separator.rest.items.len);
}

test "help marks a trailing argument" {
    const schema = Command{
        .name = "run",
        .args = &.{.{ .name = "words", .variadic = true, .trailing = true, .description = "The command." }},
    };
    const help = try formatHelp(std.testing.allocator, &schema, &.{});
    defer std.testing.allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "The command. (everything after the first word is passed through)") != null);
}
