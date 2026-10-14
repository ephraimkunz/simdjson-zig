const std = @import("std");
const Io = std.Io;

const sj = @import("simdjson_zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const f = try std.Io.Dir.cwd().readFileAlloc(io, "large-file.json", init.gpa, .unlimited);
    defer gpa.free(f);

    const S = struct { type: []u8 };

    const parsed = try sj.parseFromSlice([]S, gpa, f, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    std.debug.print("{} items: {s}\n", .{ parsed.value.len, parsed.value[0].type });
}
