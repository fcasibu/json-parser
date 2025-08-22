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
