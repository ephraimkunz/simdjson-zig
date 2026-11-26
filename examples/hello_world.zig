const std = @import("std");
const sj = @import("simdjson");

pub fn main(init: std.process.Init) !void {
    const json =
        \\ { "name": "Jim Jones", "age": 32 }
    ;

    const Identity = struct { name: []u8, age: u8 };

    const parsed = try sj.parseFromSlice(Identity, init.gpa, json, .{});
    defer parsed.deinit();

    std.debug.print("Name: {s}, age: {d}\n", .{ parsed.value.name, parsed.value.age });
}
