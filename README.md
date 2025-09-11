# json-parser

A simple JSON parser for Zig.

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
exe.linkLibrary(json_dep.artifact("json"));
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

## Contributing

Contributions are welcome! Please feel free to open an issue or submit a pull request. We are all learners of zig here!

## Acknowledgments

- This project uses the [stb_c_lexer.h](https://github.com/nothings/stb) library.
