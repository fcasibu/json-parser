const c = @cImport({
    @cInclude("stb_c_lexer.h");
});
const std = @import("std");

pub const JSONValue = union(enum) {
    boolean: bool,
    null,
    string: []const u8,
    number: JSONNumber,
    object: *JSONObject,
    array: *JSONArray,
};
pub const JSONField = struct { key: []const u8, value: JSONValue };
pub const JSONObject = struct { items: []JSONField };
pub const JSONArray = struct { items: []JSONValue };
pub const JSONNumber = struct { raw: []const u8, value: f64 };

// TODO(fcasibu): Diagnostics
const ParseError = error{ OutOfMemory, UnexpectedToken, InvalidIdentifier };

const Context = struct { source: []const u8, lexer: *c.stb_lexer, allocator: std.mem.Allocator };

pub fn parse(allocator: std.mem.Allocator, file_content: []const u8) ParseError!JSONValue {
    var json_value: JSONValue = undefined;

    var lexer: c.stb_lexer = undefined;
    const string_store = try allocator.alloc(u8, file_content.len);
    const string_store_len: c_int = @intCast(string_store.len);
    defer allocator.free(string_store);

    c.stb_c_lexer_init(&lexer, file_content.ptr, file_content.ptr + file_content.len, string_store.ptr, string_store_len);

    const context = Context{ .allocator = allocator, .lexer = &lexer, .source = file_content };

    next(&lexer);

    switch (lexer.token) {
        c.CLEX_dqstring => {
            json_value = try parseString(context);
        },
        c.CLEX_intlit => {
            json_value = try parseInt(context);
        },
        c.CLEX_floatlit => {
            json_value = try parseFloat(context);
        },
        c.CLEX_id => {
            json_value = try parseIdentifier(context);
        },
        else => {
            const is_ascii = lexer.token >= 0 and lexer.token < 256;
            if (!is_ascii) {
                return ParseError.UnexpectedToken;
            }

            const tok = @as(u8, @intCast(lexer.token));
            if (tok == '{') {
                json_value = JSONValue{ .object = try parseObject(context) };
            } else if (tok == '[') {
                json_value = JSONValue{ .array = try parseArray(context) };
            } else if (tok == '-') {
                json_value = try parseNumberWithSign(context);
            } else {
                return ParseError.UnexpectedToken;
            }
        },
    }

    try consumeAndExpectToken(context, c.CLEX_eof);
    return json_value;
}

pub fn print(json_value: JSONValue) void {
    switch (json_value) {
        .string => |string| printString(string),
        .number => |number| printNumber(number),
        .boolean => |boolean| printBool(boolean),
        .null => printNull(),
        .object => |object| printObject(object, 0),
        .array => |array| printArray(array, 0),
    }
}

pub fn free(allocator: std.mem.Allocator, value: *JSONValue) void {
    switch (value.*) {
        .string => |string| {
            allocator.free(string);
        },
        .number, .boolean, .null => {},
        .object => |obj| {
            for (obj.items) |*field| {
                allocator.free(field.key);
                free(allocator, &field.value);
            }
            allocator.free(obj.items);
            allocator.destroy(obj);
        },
        .array => |arr| {
            for (arr.items) |*item| {
                free(allocator, item);
            }
            allocator.free(arr.items);
            allocator.destroy(arr);
        },
    }
}

inline fn next(lex: *c.stb_lexer) void {
    _ = c.stb_c_lexer_get_token(lex);
}

fn expectToken(lexer: *c.stb_lexer, token: c_int) !void {
    if (token != lexer.token) {
        return ParseError.UnexpectedToken;
    }
}

fn consumeAndExpectToken(context: Context, token: c_int) !void {
    next(context.lexer);
    try expectToken(context.lexer, token);
}

fn parseString(context: Context) !JSONValue {
    // TODO(fcasibu): control characters, etc
    try expectToken(context.lexer, c.CLEX_dqstring);
    const value: []const u8 = try context.allocator.dupe(u8, std.mem.span(context.lexer.string));
    return JSONValue{ .string = value };
}

fn sliceNumber(context: Context, first_char: ?[*c]u8) []const u8 {
    const base: usize = @intFromPtr(context.source.ptr);
    const start: usize = @intFromPtr(first_char orelse context.lexer.where_firstchar) - base;

    const end: usize = (@intFromPtr(context.lexer.where_lastchar) - base) + 1;

    return context.source[start..end];
}

fn parseNumberWithSign(context: Context) ParseError!JSONValue {
    try expectToken(context.lexer, '-');
    const minus_start = context.lexer.where_firstchar;
    next(context.lexer);

    switch (context.lexer.token) {
        c.CLEX_intlit => return .{ .number = JSONNumber{ .raw = sliceNumber(context, minus_start), .value = -@as(f64, @floatFromInt(context.lexer.int_number)) } },
        c.CLEX_floatlit => return .{ .number = JSONNumber{ .raw = sliceNumber(context, minus_start), .value = -context.lexer.real_number } },
        else => return error.UnexpectedToken,
    }
}

fn parseInt(context: Context) !JSONValue {
    try expectToken(context.lexer, c.CLEX_intlit);

    return JSONValue{ .number = JSONNumber{ .raw = sliceNumber(context, null), .value = @as(f64, @floatFromInt(context.lexer.int_number)) } };
}

fn parseFloat(context: Context) !JSONValue {
    try expectToken(context.lexer, c.CLEX_floatlit);

    return JSONValue{ .number = JSONNumber{ .raw = sliceNumber(context, null), .value = context.lexer.real_number } };
}

fn parseIdentifier(context: Context) !JSONValue {
    try expectToken(context.lexer, c.CLEX_id);
    const s = std.mem.span(context.lexer.string);

    if (std.mem.eql(u8, s, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, s, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, s, "null")) return .{ .null = {} };

    return ParseError.InvalidIdentifier;
}

fn parseObject(ctx: Context) ParseError!*JSONObject {
    try expectToken(ctx.lexer, '{');

    var fields = std.ArrayList(JSONField).init(ctx.allocator);

    errdefer {
        for (fields.items) |*f| {
            ctx.allocator.free(f.key);
            free(ctx.allocator, &f.value);
        }
        fields.deinit();
    }

    next(ctx.lexer);
    if (ctx.lexer.token == '}') {
        const obj = try ctx.allocator.create(JSONObject);
        errdefer ctx.allocator.destroy(obj);
        obj.items = try ctx.allocator.alloc(JSONField, 0);
        return obj;
    }

    while (true) {
        var pending_key: ?[]u8 = null;
        var pending_val: ?JSONValue = null;
        errdefer {
            if (pending_key) |k| ctx.allocator.free(k);
            if (pending_val) |*v| free(ctx.allocator, v);
        }

        try expectToken(ctx.lexer, c.CLEX_dqstring);
        pending_key = try ctx.allocator.dupe(u8, std.mem.span(ctx.lexer.string));

        next(ctx.lexer);
        try expectToken(ctx.lexer, ':');

        next(ctx.lexer);
        pending_val = try parseValueFromToken(ctx);

        fields.append(.{ .key = pending_key.?, .value = pending_val.? }) catch |e| {
            ctx.allocator.free(pending_key.?);
            free(ctx.allocator, &pending_val.?);
            pending_key = null;
            pending_val = null;
            return e;
        };

        pending_key = null;
        pending_val = null;

        next(ctx.lexer);
        if (ctx.lexer.token == '}') break;
        try expectToken(ctx.lexer, ',');
        next(ctx.lexer);
    }

    try expectToken(ctx.lexer, '}');

    const obj = try ctx.allocator.create(JSONObject);
    errdefer ctx.allocator.destroy(obj);

    obj.items = try fields.toOwnedSlice();
    return obj;
}

fn parseArray(ctx: Context) ParseError!*JSONArray {
    try expectToken(ctx.lexer, '[');

    var values = std.ArrayList(JSONValue).init(ctx.allocator);
    errdefer {
        for (values.items) |*v| free(ctx.allocator, v);
        values.deinit();
    }

    next(ctx.lexer);
    if (ctx.lexer.token == ']') {
        const arr = try ctx.allocator.create(JSONArray);
        errdefer ctx.allocator.destroy(arr);
        arr.items = try ctx.allocator.alloc(JSONValue, 0);
        return arr;
    }

    while (true) {
        var pending: ?JSONValue = try parseValueFromToken(ctx);
        values.append(pending.?) catch |e| {
            free(ctx.allocator, &pending.?);
            pending = null;
            return e;
        };
        pending = null;

        next(ctx.lexer);
        if (ctx.lexer.token == ']') break;
        try expectToken(ctx.lexer, ',');
        next(ctx.lexer);
    }

    try expectToken(ctx.lexer, ']');

    const arr = try ctx.allocator.create(JSONArray);
    errdefer ctx.allocator.destroy(arr);

    arr.items = try values.toOwnedSlice();
    return arr;
}

fn parseValueFromToken(context: Context) !JSONValue {
    switch (context.lexer.token) {
        c.CLEX_dqstring => return try parseString(context),
        c.CLEX_intlit => return parseInt(context),
        c.CLEX_floatlit => return parseFloat(context),
        c.CLEX_id => return try parseIdentifier(context),
        else => {
            if (context.lexer.token >= 0 and context.lexer.token < 256) {
                const tok: u8 = @intCast(context.lexer.token);
                if (tok == '{') return .{ .object = try parseObject(context) };
                if (tok == '[') return .{ .array = try parseArray(context) };
                if (tok == '-') return try parseNumberWithSign(context);
            }
        },
    }

    return ParseError.UnexpectedToken;
}

fn printIndent(level: usize, is_last: bool) void {
    if (level > 0) {
        var i: usize = 0;
        while (i < level - 1) : (i += 1) {
            std.debug.print("│   ", .{});
        }
        if (is_last) {
            std.debug.print("└── ", .{});
        } else {
            std.debug.print("├── ", .{});
        }
    }
}

fn printString(value: []const u8) void {
    std.debug.print("String \"{s}\"\n", .{value});
}

fn printNumber(value: JSONNumber) void {
    std.debug.print("Number raw=\"{s}\", value={d:.}\n", .{ value.raw, value.value });
}

fn printBool(value: bool) void {
    std.debug.print("Boolean {}\n", .{value});
}

fn printNull() void {
    std.debug.print("Null\n", .{});
}

fn printObject(json_object: *JSONObject, level: usize) void {
    std.debug.print("JSONObject\n", .{});

    const len = json_object.items.len;
    for (json_object.items, 0..) |item, idx| {
        const is_last = idx == len - 1;

        printIndent(level + 1, is_last);
        std.debug.print("JSONField key=\"{s}\"\n", .{item.key});

        switch (item.value) {
            .string => |s| {
                printIndent(level + 2, true);
                printString(s);
            },
            .number => |n| {
                printIndent(level + 2, true);
                printNumber(n);
            },
            .object => |o| {
                printIndent(level + 2, true);
                printObject(o, level + 2);
            },
            .boolean => |b| {
                printIndent(level + 2, true);
                printBool(b);
            },
            .null => {
                printIndent(level + 2, true);
                printNull();
            },
            .array => |a| {
                printIndent(level + 2, true);
                printArray(a, level + 2);
            },
        }
    }
}

fn printArray(json_array: *JSONArray, level: usize) void {
    std.debug.print("JSONArray\n", .{});

    const len = json_array.items.len;
    for (json_array.items, 0..) |item, idx| {
        const is_last = idx == len - 1;

        printIndent(level + 1, is_last);
        switch (item) {
            .string => |s| printString(s),
            .number => |n| printNumber(n),
            .boolean => |b| printBool(b),
            .null => printNull(),
            .object => |o| printObject(o, level + 2),
            .array => |a| {
                std.debug.print("Array\n", .{});
                printIndent(level + 2, true);
                printArray(a, level + 2);
            },
        }
    }
}
