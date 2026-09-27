const std = @import("std");
const json = @import("json");

test "simple object" {
    const allocator = std.testing.allocator;

    const input = "{ \"age\": 17, \"name\": \"Alice\", \"is_student\": true }";

    const Person = struct {
        age: u8,
        name: []const u8,
        is_student: bool,
    };

    var json_value = try json.parse(allocator, input);
    defer json.free(allocator, &json_value);

    const person = try json.into(Person, json_value, allocator);
    defer allocator.free(person.name);

    try std.testing.expectEqual(17, person.age);
    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(true, person.is_student);
}

test "primitives" {
    const allocator = std.testing.allocator;

    const Primitives = struct {
        a: []const u8,
        b: i32,
        c: f64,
        d: bool,
        e: ?[]const u8,
    };

    const input = "{\"a\": \"hello\", \"b\": 123, \"c\": 1.23, \"d\": false, \"e\": null }";

    var json_value = try json.parse(allocator, input);
    defer json.free(allocator, &json_value);

    const primitives = try json.into(Primitives, json_value, allocator);
    defer {
        allocator.free(primitives.a);
        if (primitives.e) |v| {
            allocator.free(v);
        }
    }

    try std.testing.expectEqualStrings("hello", primitives.a);
    try std.testing.expectEqual(123, primitives.b);
    try std.testing.expectEqual(1.23, primitives.c);
    try std.testing.expectEqual(false, primitives.d);
    try std.testing.expectEqual(null, primitives.e);
}

test "nested object" {
    const allocator = std.testing.allocator;

    const Nested = struct {
        a: struct {
            b: i32,
        },
    };

    const input = "{\"a\": { \"b\": 123 } }";

    var json_value = try json.parse(allocator, input);
    defer json.free(allocator, &json_value);

    const nested = try json.into(Nested, json_value, allocator);

    try std.testing.expectEqual(123, nested.a.b);
}

test "array of objects" {
    const allocator = std.testing.allocator;

    const Item = struct { a: i32 };

    const List = struct {
        items: []Item,
    };

    const input = "{\"items\": [{\"a\": 1}, {\"a\": 2}] }";

    var json_value = try json.parse(allocator, input);
    defer json.free(allocator, &json_value);

    const list = try json.into(List, json_value, allocator);
    defer allocator.free(list.items);

    try std.testing.expectEqual(2, list.items.len);
    try std.testing.expectEqual(1, list.items[0].a);
    try std.testing.expectEqual(2, list.items[1].a);
}

test "numeric extremes" {
    const allocator = std.testing.allocator;

    const Numbers = struct {
        max_safe_int: i64,
        min_safe_int: i64,
        min_float: f64,
        max_float: f64,
    };

    const input =
        \\ { 
        \\  "max_safe_int": 9007199254740991,
        \\  "min_safe_int": -9007199254740991,
        \\  "min_float": -1.7976931348623157e+308,
        \\  "max_float": 1.7976931348623157e+308
        \\ }
    ;

    var json_value = try json.parse(allocator, input);
    defer json.free(allocator, &json_value);

    const numbers = try json.into(Numbers, json_value, allocator);

    try std.testing.expectEqual(9007199254740991, numbers.max_safe_int);
    try std.testing.expectEqual(-9007199254740991, numbers.min_safe_int);
    try std.testing.expectEqual(-1.7976931348623157e+308, numbers.min_float);
    try std.testing.expectEqual(1.7976931348623157e+308, numbers.max_float);
}

test "string escapes" {
    const allocator = std.testing.allocator;

    const input = "{\"a\": \"\\\"\\\\\\/\\b\\f\\n\\r\\t\", \"b\": \"\\u0041\", \"c\": \"\\uD83D\\uDE00\"}";

    var json_value = try json.parse(allocator, input);
    defer json.free(allocator, &json_value);

    try std.testing.expectEqualStrings("\"\\/\x08\x0c\n\r\t", json_value.object.items[0].value.string);
    try std.testing.expectEqualStrings("A", json_value.object.items[1].value.string);
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", json_value.object.items[2].value.string);
}

test "top-level primitives" {
    const allocator = std.testing.allocator;

    var s = try json.parse(allocator, "\"hi\"");
    defer json.free(allocator, &s);
    try std.testing.expectEqualStrings("hi", s.string);

    var n = try json.parse(allocator, "-12.5e3");
    defer json.free(allocator, &n);
    try std.testing.expectEqualStrings("-12.5e3", n.number.raw);
    try std.testing.expectEqual(-12500.0, n.number.value);

    var t = try json.parse(allocator, "true");
    defer json.free(allocator, &t);
    try std.testing.expectEqual(true, t.boolean);

    var nul = try json.parse(allocator, "null");
    defer json.free(allocator, &nul);
    try std.testing.expect(nul == .null);

    var arr = try json.parse(allocator, "[1, \"a\", null]");
    defer json.free(allocator, &arr);
    try std.testing.expectEqual(3, arr.array.items.len);
}

test "rejects invalid numbers" {
    const allocator = std.testing.allocator;
    const bad = [_][]const u8{ "01", "+1", ".5", "1.", "0x1", "NaN", "1e", "--1", "-", "1e+", "{\"a\": 01}" };

    for (bad) |input| {
        var diag: json.Diagnostic = .{};
        const result = json.parseDetailed(allocator, input, &diag);
        if (result) |*v| {
            var owned = v.*;
            json.free(allocator, &owned);
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "rejects comments and single quotes" {
    const allocator = std.testing.allocator;

    const bad = [_][]const u8{
        "{\"a\": 1 /* x */}",
        "{\"a\": 1 // x\n}",
        "{'a': 1}",
        "{\"a\": 'x'}",
    };

    for (bad) |input| {
        const result = json.parse(allocator, input);
        if (result) |*v| {
            var owned = v.*;
            json.free(allocator, &owned);
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "rejects malformed structure" {
    const allocator = std.testing.allocator;

    const bad = [_][]const u8{
        "{\"a\": 1,}",
        "[1, 2,]",
        "{\"a\" 1}",
        "{\"a\": 1 2}",
        "{\"a\": 1",
        "[1, 2",
        "{\"a\": 1} trailing",
        "",
        "   ",
        "{\"a\": 1, \"a\": 2}",
        "{\"a\": tru}",
        "{\"a\": nul}",
        "{\"a\": \"\\x\"}",
        "{\"a\": \"\\ud800\"}",
        "{\"a\": \"unterminated}",
        "{\"a\": - 1}",
    };

    for (bad) |input| {
        const result = json.parse(allocator, input);
        if (result) |*v| {
            var owned = v.*;
            json.free(allocator, &owned);
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "diagnostic location" {
    const allocator = std.testing.allocator;

    var diag: json.Diagnostic = .{};
    const result = json.parseDetailed(allocator, "{\n  \"a\": 1,\n  \"b\": \n}", &diag);
    if (result) |*v| {
        var owned = v.*;
        json.free(allocator, &owned);
        return error.TestExpectedError;
    } else |_| {}

    try std.testing.expectEqual(4, diag.line);
    try std.testing.expect(diag.offset > 0);
}

test "into enum, defaults and optionals" {
    const allocator = std.testing.allocator;

    const Color = enum { red, green, blue };
    const Config = struct {
        color: Color,
        nickname: ?[]const u8 = null,
        retries: u8 = 3,
    };

    var json_value = try json.parse(allocator, "{\"color\": \"green\"}");
    defer json.free(allocator, &json_value);

    var config = try json.into(Config, json_value, allocator);
    defer json.freeMapped(Config, &config, allocator);

    try std.testing.expectEqual(Color.green, config.color);
    try std.testing.expectEqual(null, config.nickname);
    try std.testing.expectEqual(3, config.retries);

    var bad_value = try json.parse(allocator, "{\"color\": \"purple\"}");
    defer json.free(allocator, &bad_value);
    try std.testing.expectError(json.ParseError.TypeMismatch, json.into(Config, bad_value, allocator));
}

test "into fixed arrays and int validation" {
    const allocator = std.testing.allocator;

    const Pair = struct { v: [2]i32 };

    var json_value = try json.parse(allocator, "{\"v\": [1, 1e1]}");
    defer json.free(allocator, &json_value);

    const pair = try json.into(Pair, json_value, allocator);
    try std.testing.expectEqual([2]i32{ 1, 10 }, pair.v);

    var frac_value = try json.parse(allocator, "{\"v\": [1, 1.5]}");
    defer json.free(allocator, &frac_value);
    try std.testing.expectError(json.ParseError.TypeMismatch, json.into(Pair, frac_value, allocator));

    var big_value = try json.parse(allocator, "{\"v\": [1, 9999999999]}");
    defer json.free(allocator, &big_value);
    try std.testing.expectError(json.ParseError.TypeMismatch, json.into(struct { v: [2]i32 }, big_value, allocator));
}

test "stringify round-trip" {
    const allocator = std.testing.allocator;

    var json_value = try json.parse(allocator, "{\"a\": [1, \"x\\n\", null], \"b\": {}}");
    defer json.free(allocator, &json_value);

    const text = try json.stringifyAlloc(allocator, json_value);
    defer allocator.free(text);

    try std.testing.expectEqualStrings("{\"a\":[1,\"x\\n\",null],\"b\":{}}", text);

    var reparsed = try json.parse(allocator, text);
    defer json.free(allocator, &reparsed);
    try std.testing.expectEqual(2, reparsed.object.items.len);
}
