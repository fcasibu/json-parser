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

    var parsed = try json.parse(Person, allocator, input);
    defer {
        allocator.free(parsed.value.name);
        json.free(allocator, &parsed.json_value);
    }

    try std.testing.expectEqual(17, parsed.value.age);
    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqual(true, parsed.value.is_student);
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

    var parsed = try json.parse(Primitives, allocator, input);
    defer {
        allocator.free(parsed.value.a);
        if (parsed.value.e) |v| {
            allocator.free(v);
        }
        json.free(allocator, &parsed.json_value);
    }

    try std.testing.expectEqualStrings("hello", parsed.value.a);
    try std.testing.expectEqual(123, parsed.value.b);
    try std.testing.expectEqual(1.23, parsed.value.c);
    try std.testing.expectEqual(false, parsed.value.d);
    try std.testing.expectEqual(null, parsed.value.e);
}

test "nested object" {
    const allocator = std.testing.allocator;

    const Nested = struct {
        a: struct {
            b: i32,
        },
    };

    const input = "{\"a\": { \"b\": 123 } }";

    var parsed = try json.parse(Nested, allocator, input);
    defer json.free(allocator, &parsed.json_value);

    try std.testing.expectEqual(123, parsed.value.a.b);
}

test "array of objects" {
    const allocator = std.testing.allocator;

    const Item = struct { a: i32 };

    const List = struct {
        items: []Item,
    };

    const input = "{\"items\": [{\"a\": 1}, {\"a\": 2}] }";

    var parsed = try json.parse(List, allocator, input);
    defer {
        allocator.free(parsed.value.items);
        json.free(allocator, &parsed.json_value);
    }

    try std.testing.expectEqual(2, parsed.value.items.len);
    try std.testing.expectEqual(1, parsed.value.items[0].a);
    try std.testing.expectEqual(2, parsed.value.items[1].a);
}
