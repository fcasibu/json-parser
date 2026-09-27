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

pub const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    UnexpectedEnd,
    InvalidLiteral,
    InvalidIdentifier,
    InvalidNumber,
    NumberOutOfRange,
    InvalidEscape,
    InvalidUnicodeEscape,
    ControlCharacterInString,
    UnterminatedString,
    UnterminatedValue,
    MissingColon,
    MissingComma,
    TrailingData,
    DuplicateField,
    DepthExceeded,
    TypeMismatch,
    MissingField,
    UnsupportedType,
    FixedArrayLengthMismatch,
};

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    offset: usize = 0,
    message: []const u8 = "ok",
};

pub var last_diagnostic: Diagnostic = .{};

pub const max_depth: usize = 128;

const Parser = struct {
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    column: usize = 1,
    allocator: std.mem.Allocator,
    depth: usize = 0,
    diag: Diagnostic = .{},

    fn eof(self: *Parser) bool {
        return self.pos >= self.source.len;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.eof()) return null;
        return self.source[self.pos];
    }

    fn advance(self: *Parser) ?u8 {
        if (self.eof()) return null;
        const ch = self.source[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return ch;
    }

    fn fail(self: *Parser, err: ParseError, message: []const u8) ParseError {
        self.diag = .{
            .line = self.line,
            .column = self.column,
            .offset = self.pos,
            .message = message,
        };
        return err;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |ch| {
            switch (ch) {
                ' ', '\t', '\n', '\r' => _ = self.advance(),
                else => return,
            }
        }
    }
};

pub fn into(comptime T: type, json_value: JSONValue, allocator: std.mem.Allocator) ParseError!T {
    return try jsonValueToType(T, json_value, allocator);
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8) ParseError!JSONValue {
    var diag: Diagnostic = .{};
    return parseDetailed(allocator, content, &diag) catch |err| {
        last_diagnostic = diag;
        return err;
    };
}

pub fn parseDetailed(allocator: std.mem.Allocator, content: []const u8, out: *Diagnostic) ParseError!JSONValue {
    var parser = Parser{ .source = content, .allocator = allocator };

    if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) {
        parser.pos = 3;
        parser.column = 4;
    }

    parser.skipWhitespace();
    if (parser.eof()) {
        out.* = .{ .line = parser.line, .column = parser.column, .offset = parser.pos, .message = "empty input" };
        last_diagnostic = out.*;
        return ParseError.UnexpectedEnd;
    }

    const value = parseValue(&parser) catch |err| {
        out.* = parser.diag;
        last_diagnostic = out.*;
        return err;
    };

    parser.skipWhitespace();
    if (!parser.eof()) {
        var owned = value;
        free(allocator, &owned);
        out.* = .{ .line = parser.line, .column = parser.column, .offset = parser.pos, .message = "trailing characters after JSON value" };
        last_diagnostic = out.*;
        return ParseError.TrailingData;
    }

    out.* = .{};
    return value;
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

pub fn stringify(json_value: JSONValue, writer: anytype) !void {
    switch (json_value) {
        .null => try writer.writeAll("null"),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .number => |n| try writer.writeAll(n.raw),
        .string => |s| try writeQuotedString(s, writer),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try stringify(item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            for (obj.items, 0..) |field, i| {
                if (i > 0) try writer.writeByte(',');
                try writeQuotedString(field.key, writer);
                try writer.writeByte(':');
                try stringify(field.value, writer);
            }
            try writer.writeByte('}');
        },
    }
}

pub fn stringifyAlloc(allocator: std.mem.Allocator, json_value: JSONValue) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    switch (json_value) {
        .null => try buf.appendSlice(allocator, "null"),
        .boolean => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .number => |n| try buf.appendSlice(allocator, n.raw),
        .string => |s| try appendQuotedString(allocator, &buf, s),
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                const child = try stringifyAlloc(allocator, item);
                defer allocator.free(child);
                try buf.appendSlice(allocator, child);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            for (obj.items, 0..) |field, i| {
                if (i > 0) try buf.append(allocator, ',');
                try appendQuotedString(allocator, &buf, field.key);
                try buf.append(allocator, ':');
                const child = try stringifyAlloc(allocator, field.value);
                defer allocator.free(child);
                try buf.appendSlice(allocator, child);
            }
            try buf.append(allocator, '}');
        },
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn free(allocator: std.mem.Allocator, value: *JSONValue) void {
    switch (value.*) {
        .string => |string| {
            allocator.free(string);
        },
        .number => |num| {
            allocator.free(num.raw);
        },
        .boolean, .null => {},
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

pub fn freeMapped(comptime T: type, value: *T, allocator: std.mem.Allocator) void {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .pointer => |p| {
            if (p.size != .slice) return;
            if (p.child == u8) {
                allocator.free(value.*);
                return;
            }
            for (value.*) |*item| {
                freeMapped(p.child, item, allocator);
            }
            allocator.free(value.*);
        },
        .array => |a| {
            for (value) |*item| {
                freeMapped(a.child, item, allocator);
            }
        },
        .optional => |o| {
            if (value.*) |*child| {
                freeMapped(o.child, child, allocator);
            }
        },
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                freeMapped(field.type, &@field(value.*, field.name), allocator);
            }
        },
        else => {},
    }
}

fn jsonValueToType(comptime T: type, json_value: JSONValue, allocator: std.mem.Allocator) ParseError!T {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => |p| {
            if (p.size != .slice) return ParseError.UnsupportedType;

            if (p.child == u8) {
                switch (json_value) {
                    .string => |s| return try allocator.dupe(u8, s),
                    else => return ParseError.TypeMismatch,
                }
            }

            return try jsonValueToArray(T, json_value, allocator);
        },
        .int => {
            switch (json_value) {
                .number => |n| return try numberToInt(T, n),
                else => return ParseError.TypeMismatch,
            }
        },
        .float => {
            switch (json_value) {
                .number => |n| {
                    const v = std.fmt.parseFloat(T, n.raw) catch return ParseError.TypeMismatch;
                    return v;
                },
                else => return ParseError.TypeMismatch,
            }
        },
        .bool => {
            switch (json_value) {
                .boolean => |b| return b,
                else => return ParseError.TypeMismatch,
            }
        },
        .optional => |o| {
            switch (json_value) {
                .null => return null,
                else => {
                    const child = try jsonValueToType(o.child, json_value, allocator);
                    return @as(T, child);
                },
            }
        },
        .void => {
            switch (json_value) {
                .null => return {},
                else => return ParseError.TypeMismatch,
            }
        },
        .array => |arr_info| {
            switch (json_value) {
                .array => |a| {
                    if (a.items.len != arr_info.len) {
                        return ParseError.FixedArrayLengthMismatch;
                    }

                    return try jsonValueToFixedArray(T, json_value, allocator);
                },
                else => return ParseError.TypeMismatch,
            }
        },
        .@"enum" => {
            switch (json_value) {
                .string => |s| return std.meta.stringToEnum(T, s) orelse ParseError.TypeMismatch,
                else => return ParseError.TypeMismatch,
            }
        },
        .@"struct" => return jsonValueToStruct(T, json_value, allocator),
        else => return ParseError.UnsupportedType,
    }
}

fn numberToInt(comptime Int: type, num: JSONNumber) ParseError!Int {
    if (std.fmt.parseInt(Int, num.raw, 10)) |v| {
        return v;
    } else |_| {}

    const as_float = std.fmt.parseFloat(f64, num.raw) catch return ParseError.TypeMismatch;
    if (@floor(as_float) != as_float) return ParseError.TypeMismatch;

    const info = @typeInfo(Int).int;
    const min: f64 = switch (info.signedness) {
        .signed => @as(f64, @floatFromInt(std.math.minInt(Int))),
        .unsigned => 0,
    };
    const max: f64 = @as(f64, @floatFromInt(std.math.maxInt(Int)));
    if (as_float < min or as_float > max) return ParseError.TypeMismatch;

    return @as(Int, @intFromFloat(as_float));
}

fn jsonValueToStruct(comptime T: type, json_value: JSONValue, allocator: std.mem.Allocator) ParseError!T {
    const type_info = @typeInfo(T);
    const s = type_info.@"struct";

    const obj: *JSONObject = switch (json_value) {
        .object => |o| o,
        else => return ParseError.TypeMismatch,
    };

    var result: T = undefined;
    var owned: [s.fields.len]bool = @splat(false);

    errdefer {
        inline for (s.fields, 0..) |field, idx| {
            if (owned[idx]) {
                freeMapped(field.type, &@field(result, field.name), allocator);
            }
        }
    }

    inline for (s.fields, 0..) |field, idx| {
        var field_value: ?JSONValue = null;

        for (obj.items) |item| {
            if (std.mem.eql(u8, item.key, field.name)) {
                field_value = item.value;
                break;
            }
        }

        if (field_value) |v| {
            @field(result, field.name) = try jsonValueToType(field.type, v, allocator);
            owned[idx] = true;
        } else if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            return ParseError.MissingField;
        }
    }

    return result;
}

fn jsonValueToArray(comptime T: type, json_value: JSONValue, allocator: std.mem.Allocator) ParseError!T {
    const type_info = @typeInfo(T);
    const p = type_info.pointer;

    const arr: *JSONArray = switch (json_value) {
        .array => |a| a,
        else => return ParseError.TypeMismatch,
    };

    var list: std.ArrayList(p.child) = .empty;
    errdefer {
        for (list.items) |*item| {
            freeMapped(p.child, item, allocator);
        }
        list.deinit(allocator);
    }

    for (arr.items) |item| {
        var v = try jsonValueToType(p.child, item, allocator);
        list.append(allocator, v) catch |err| {
            freeMapped(p.child, &v, allocator);
            return err;
        };
    }

    return try list.toOwnedSlice(allocator);
}

fn jsonValueToFixedArray(comptime T: type, json_value: JSONValue, allocator: std.mem.Allocator) ParseError!T {
    const type_info = @typeInfo(T);

    const arr: *JSONArray = switch (json_value) {
        .array => |a| a,
        else => return ParseError.TypeMismatch,
    };

    var result: T = undefined;
    var done: usize = 0;

    errdefer {
        for (result[0..done]) |*item| {
            freeMapped(type_info.array.child, item, allocator);
        }
    }

    for (arr.items, 0..) |item, idx| {
        result[idx] = try jsonValueToType(type_info.array.child, item, allocator);
        done += 1;
    }

    return result;
}

fn parseValue(parser: *Parser) ParseError!JSONValue {
    parser.skipWhitespace();

    const ch = parser.peek() orelse return parser.fail(ParseError.UnexpectedEnd, "unexpected end of input");
    switch (ch) {
        '{' => return try parseObject(parser),
        '[' => return try parseArray(parser),
        '"' => {
            const s = try parseString(parser);
            return .{ .string = s };
        },
        't', 'f', 'n' => return try parseLiteral(parser),
        '-', '0'...'9' => return try parseNumber(parser),
        else => return parser.fail(ParseError.UnexpectedToken, "unexpected character"),
    }
}

fn parseObject(parser: *Parser) ParseError!JSONValue {
    if (parser.depth >= max_depth) return parser.fail(ParseError.DepthExceeded, "maximum nesting depth exceeded");
    parser.depth += 1;
    defer parser.depth -= 1;

    _ = parser.advance(); // consume '{'
    parser.skipWhitespace();

    var fields: std.ArrayList(JSONField) = .empty;
    errdefer {
        for (fields.items) |*f| {
            parser.allocator.free(f.key);
            var v = f.value;
            free(parser.allocator, &v);
        }
        fields.deinit(parser.allocator);
    }

    if (parser.peek() == '}') {
        _ = parser.advance();
        const obj = try parser.allocator.create(JSONObject);
        errdefer parser.allocator.destroy(obj);
        obj.items = try fields.toOwnedSlice(parser.allocator);
        return .{ .object = obj };
    }

    while (true) {
        parser.skipWhitespace();
        if (parser.peek() != '"') {
            return parser.fail(ParseError.UnexpectedToken, "expected string key");
        }

        const field = try parseObjectField(parser);

        for (fields.items) |existing| {
            if (std.mem.eql(u8, existing.key, field.key)) {
                var owned = field;
                parser.allocator.free(owned.key);
                free(parser.allocator, &owned.value);
                return parser.fail(ParseError.DuplicateField, "duplicate object field");
            }
        }

        fields.append(parser.allocator, field) catch |err| {
            var owned = field;
            parser.allocator.free(owned.key);
            free(parser.allocator, &owned.value);
            return err;
        };

        parser.skipWhitespace();
        const next = parser.peek() orelse return parser.fail(ParseError.UnterminatedValue, "unterminated object");
        if (next == '}') {
            _ = parser.advance();
            break;
        }
        if (next != ',') {
            return parser.fail(ParseError.MissingComma, "expected ',' or '}' in object");
        }
        _ = parser.advance();
    }

    const obj = try parser.allocator.create(JSONObject);
    errdefer parser.allocator.destroy(obj);

    obj.items = try fields.toOwnedSlice(parser.allocator);
    return .{ .object = obj };
}

fn parseObjectField(parser: *Parser) ParseError!JSONField {
    const key: []u8 = try parseString(parser);
    errdefer parser.allocator.free(key);

    parser.skipWhitespace();
    if (parser.peek() != ':') {
        return parser.fail(ParseError.MissingColon, "expected ':' after object key");
    }
    _ = parser.advance();

    const value = try parseValue(parser);
    errdefer {
        var owned = value;
        free(parser.allocator, &owned);
    }

    return .{ .key = key, .value = value };
}

fn parseArray(parser: *Parser) ParseError!JSONValue {
    if (parser.depth >= max_depth) return parser.fail(ParseError.DepthExceeded, "maximum nesting depth exceeded");
    parser.depth += 1;
    defer parser.depth -= 1;

    _ = parser.advance(); // consume '['
    parser.skipWhitespace();

    var values: std.ArrayList(JSONValue) = .empty;
    errdefer {
        for (values.items) |*v| free(parser.allocator, v);
        values.deinit(parser.allocator);
    }

    if (parser.peek() == ']') {
        _ = parser.advance();
        const arr = try parser.allocator.create(JSONArray);
        errdefer parser.allocator.destroy(arr);
        arr.items = try values.toOwnedSlice(parser.allocator);
        return .{ .array = arr };
    }

    while (true) {
        const value = try parseValue(parser);

        values.append(parser.allocator, value) catch |err| {
            var owned = value;
            free(parser.allocator, &owned);
            return err;
        };

        parser.skipWhitespace();
        const next = parser.peek() orelse return parser.fail(ParseError.UnterminatedValue, "unterminated array");
        if (next == ']') {
            _ = parser.advance();
            break;
        }
        if (next != ',') {
            return parser.fail(ParseError.MissingComma, "expected ',' or ']' in array");
        }
        _ = parser.advance();
    }

    const arr = try parser.allocator.create(JSONArray);
    errdefer parser.allocator.destroy(arr);

    arr.items = try values.toOwnedSlice(parser.allocator);
    return .{ .array = arr };
}

fn parseLiteral(parser: *Parser) ParseError!JSONValue {
    const rest = parser.source[parser.pos..];

    if (std.mem.startsWith(u8, rest, "true")) {
        if (rest.len > 4 and isLiteralTail(rest[4])) {
            return parser.fail(ParseError.InvalidLiteral, "invalid literal");
        }
        advanceBy(parser, 4);
        return .{ .boolean = true };
    }
    if (std.mem.startsWith(u8, rest, "false")) {
        if (rest.len > 5 and isLiteralTail(rest[5])) {
            return parser.fail(ParseError.InvalidLiteral, "invalid literal");
        }
        advanceBy(parser, 5);
        return .{ .boolean = false };
    }
    if (std.mem.startsWith(u8, rest, "null")) {
        if (rest.len > 4 and isLiteralTail(rest[4])) {
            return parser.fail(ParseError.InvalidLiteral, "invalid literal");
        }
        advanceBy(parser, 4);
        return .{ .null = {} };
    }

    return parser.fail(ParseError.InvalidLiteral, "invalid literal, expected true/false/null");
}

fn isLiteralTail(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn advanceBy(parser: *Parser, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = parser.advance();
    }
}

fn parseNumber(parser: *Parser) ParseError!JSONValue {
    const start = parser.pos;
    var i = parser.pos;
    const source = parser.source;

    if (i < source.len and source[i] == '-') i += 1;

    if (i >= source.len) return parser.fail(ParseError.InvalidNumber, "invalid number");
    if (source[i] == '0') {
        i += 1;
        // Leading zeros like `01` are not valid JSON.
        if (i < source.len and source[i] >= '0' and source[i] <= '9') {
            return parser.fail(ParseError.InvalidNumber, "leading zeros are not allowed");
        }
    } else if (source[i] >= '1' and source[i] <= '9') {
        while (i < source.len and source[i] >= '0' and source[i] <= '9') i += 1;
    } else {
        return parser.fail(ParseError.InvalidNumber, "invalid number");
    }

    if (i < source.len and source[i] == '.') {
        i += 1;
        if (i >= source.len or source[i] < '0' or source[i] > '9') {
            return parser.fail(ParseError.InvalidNumber, "expected digit after decimal point");
        }
        while (i < source.len and source[i] >= '0' and source[i] <= '9') i += 1;
    }

    if (i < source.len and (source[i] == 'e' or source[i] == 'E')) {
        i += 1;
        if (i < source.len and (source[i] == '+' or source[i] == '-')) i += 1;
        if (i >= source.len or source[i] < '0' or source[i] > '9') {
            return parser.fail(ParseError.InvalidNumber, "expected digit in exponent");
        }
        while (i < source.len and source[i] >= '0' and source[i] <= '9') i += 1;
    }

    const raw_slice = source[start..i];
    const raw = try parser.allocator.dupe(u8, raw_slice);
    errdefer parser.allocator.free(raw);

    const value = std.fmt.parseFloat(f64, raw_slice) catch {
        return parser.fail(ParseError.NumberOutOfRange, "number out of range");
    };

    while (parser.pos < i) _ = parser.advance();

    return .{ .number = .{ .raw = raw, .value = value } };
}

fn parseString(parser: *Parser) ParseError![]u8 {
    std.debug.assert(parser.peek() == '"');
    _ = parser.advance(); // consume opening quote

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(parser.allocator);

    while (true) {
        const ch = parser.peek() orelse return parser.fail(ParseError.UnterminatedString, "unterminated string");
        if (ch == '"') {
            _ = parser.advance();
            break;
        }
        if (ch == '\\') {
            _ = parser.advance(); // consume '\'
            const esc = parser.peek() orelse return parser.fail(ParseError.UnterminatedString, "unterminated escape");
            switch (esc) {
                '"', '\\', '/' => {
                    try out.append(parser.allocator, esc);
                    _ = parser.advance();
                },
                'b' => {
                    try out.append(parser.allocator, 0x08);
                    _ = parser.advance();
                },
                'f' => {
                    try out.append(parser.allocator, 0x0C);
                    _ = parser.advance();
                },
                'n' => {
                    try out.append(parser.allocator, '\n');
                    _ = parser.advance();
                },
                'r' => {
                    try out.append(parser.allocator, '\r');
                    _ = parser.advance();
                },
                't' => {
                    try out.append(parser.allocator, '\t');
                    _ = parser.advance();
                },
                'u' => {
                    const codepoint = try parseUnicodeEscape(parser);
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                        return parser.fail(ParseError.InvalidUnicodeEscape, "invalid unicode codepoint");
                    };
                    try out.appendSlice(parser.allocator, buf[0..len]);
                },
                else => return parser.fail(ParseError.InvalidEscape, "invalid escape sequence"),
            }
            continue;
        }
        if (ch < 0x20) {
            return parser.fail(ParseError.ControlCharacterInString, "unescaped control character in string");
        }
        try out.append(parser.allocator, ch);
        _ = parser.advance();
    }

    return try out.toOwnedSlice(parser.allocator);
}

fn parseUnicodeEscape(parser: *Parser) ParseError!u21 {
    std.debug.assert(parser.peek() == 'u');
    _ = parser.advance();

    const high = try parseHex4(parser);

    if (high >= 0xD800 and high <= 0xDBFF) {
        if (parser.source.len - parser.pos < 2 or parser.source[parser.pos] != '\\' or parser.source[parser.pos + 1] != 'u') {
            return parser.fail(ParseError.InvalidUnicodeEscape, "lone high surrogate");
        }
        _ = parser.advance(); // '\'
        _ = parser.advance(); // 'u'
        const low = try parseHex4(parser);
        if (low < 0xDC00 or low > 0xDFFF) {
            return parser.fail(ParseError.InvalidUnicodeEscape, "invalid low surrogate");
        }
        const high_part: u21 = @as(u21, @intCast(high - 0xD800));
        const low_part: u21 = @as(u21, @intCast(low - 0xDC00));
        return @as(u21, 0x10000 + (high_part << 10) + low_part);
    }

    if (high >= 0xDC00 and high <= 0xDFFF) {
        return parser.fail(ParseError.InvalidUnicodeEscape, "lone low surrogate");
    }

    return @as(u21, @intCast(high));
}

fn parseHex4(parser: *Parser) ParseError!u16 {
    if (parser.pos + 4 > parser.source.len) {
        return parser.fail(ParseError.UnterminatedString, "truncated unicode escape");
    }
    var value: u16 = 0;
    for (0..4) |_| {
        const ch = parser.peek() orelse return parser.fail(ParseError.UnterminatedString, "truncated unicode escape");
        value <<= 4;
        if (ch >= '0' and ch <= '9') {
            value |= @as(u16, ch - '0');
        } else if (ch >= 'a' and ch <= 'f') {
            value |= @as(u16, ch - 'a' + 10);
        } else if (ch >= 'A' and ch <= 'F') {
            value |= @as(u16, ch - 'A' + 10);
        } else {
            return parser.fail(ParseError.InvalidUnicodeEscape, "expected hex digit in unicode escape");
        }
        _ = parser.advance();
    }
    return value;
}

fn writeQuotedString(value: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = "0123456789abcdef";
                    buf[0] = '\\';
                    buf[1] = 'u';
                    buf[2] = '0';
                    buf[3] = '0';
                    buf[4] = hex[ch >> 4];
                    buf[5] = hex[ch & 0xF];
                    try writer.writeAll(&buf);
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn appendQuotedString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    try buf.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    var esc: [6]u8 = undefined;
                    const hex = "0123456789abcdef";
                    esc[0] = '\\';
                    esc[1] = 'u';
                    esc[2] = '0';
                    esc[3] = '0';
                    esc[4] = hex[ch >> 4];
                    esc[5] = hex[ch & 0xF];
                    try buf.appendSlice(allocator, &esc);
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }
    try buf.append(allocator, '"');
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
