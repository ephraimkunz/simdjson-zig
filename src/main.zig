const std = @import("std");
const Io = std.Io;

const sj = @import("simdjson_zig");

pub fn main(init: std.process.Init) !void {
    // const source =
    //     \\ { "this is a test"  :
    //     \\ "value"        }
    // ;
    // var out: [source.len]u8 = undefined;
    // const count = try sj.minify(source, &out);
    // std.debug.print("{s}\n", .{out[0..count]});

    // const source =
    //     \\ { "this is a test"  :
    //     \\ "value"        }
    // ;
    // const result = try sj.parseFromSlice(u32, init.gpa, source, .{});

    // const source =
    //     \\ { "dinner"  :
    //     \\ "food"        }
    // ;

    // const S = struct { dinner: []const u8 };
    // const result = try sj.parseFromSlice(S, init.gpa, source, .{});
    // defer result.deinit();
    // std.debug.print("{s}\n", .{result.value.dinner});

    // const source = "5";
    // const result = try sj.parseFromSlice(u32, init.gpa, source, .{});
    // defer result.deinit();
    // std.debug.print("{}", .{result.value});

    const source =
        \\ {
        \\ "string_test": "Hello, World! 👋 \t \n \u0041",
        \\ "number_test": {
        \\ "integer": 42,
        \\ "negative": -100,
        \\ "floating_point": 3.14159,
        \\ "scientific_notation": 6.022e23,
        \\"negative_exponent": 1e-5
        \\},
        \\"boolean_test": {
        \\ "true_value": true,
        \\"false_value": false
        \\},
        \\"null_test": null,
        \\"array_test": [
        \\ "first_element",
        \\123,
        \\true,
        \\null,
        \\[
        \\ "nested_array_level_2",
        \\[
        \\ "nested_array_level_3"
        \\]
        \\]
        \\],
        \\"empty_structures": {
        \\ "empty_object": {},
        \\"empty_array": [5]
        \\}
        \\}
    ;

    const S = struct {
        empty_structures: N,
        const N = struct { empty_array: []const u8 };
    };
    const result = try sj.parseFromSlice(S, init.gpa, source, .{ .ignore_unknown_fields = true });
    defer result.deinit();
    std.debug.print("{s}", .{result.value.empty_structures.empty_array});
}
