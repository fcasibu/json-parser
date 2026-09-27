# json-parser

A simple JSON parser for Zig. Requires Zig 0.16.0 or newer.

## Installation

Download and add this lib as a dependency by running the following command in your project root:

```sh
zig fetch --save git+https://github.com/fcasibu/json-parser
```

Then, in your `build.zig` file, add the `json` module to your executable:

```zig
const json_dep = b.dependency("json", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("json", json_dep.module("json"));
```

## Usage

Here is a basic example of how to parse a JSON string into a struct:

```zig
const std = @import("std");
const json = @import("json");

const Person = struct {
    age: u8,
    name: []const u8,
    is_student: bool,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const json_string =
        \\{
        \\  "name": "John",
        \\  "age": 30,
        \\  "is_student": false
        \\}
    ;

    var json_value = try json.parse(allocator, json_string);
    defer json.free(allocator, &json_value);

    const person = try json.into(Person, json_value, allocator);
    defer allocator.free(person.name);

    std.debug.print("User: name={s}, age={d}, is_student={}", .{ person.name, person.age, person.is_student });
}
```

## Building

To build the library:

```sh
zig build
```

## Test

To run tests:

```sh
zig build test --summary all
```

## Errors and diagnostics

`parse` returns a `ParseError` (`InvalidNumber`, `MissingColon`,
`DuplicateField`, `DepthExceeded`, ...). Use `parseDetailed` or inspect
`json.last_diagnostic` right after a failure to get the `line`, `column`,
`offset`, and a human-readable `message`:

```zig
var diag: json.Diagnostic = .{};
var value = json.parseDetailed(allocator, text, &diag) catch |err| {
    std.debug.print("{s} at {d}:{d}: {s}\n", .{ @errorName(err), diag.line, diag.column, diag.message });
    return err;
};
defer json.free(allocator, &value);
```

Values produced by `into` that own memory (slices, struct fields) must be
released with `json.freeMapped(T, &value, allocator)`.

## Contributing

Contributions are welcome! Please feel free to open an issue or submit a pull request. We are all learners of zig here!
