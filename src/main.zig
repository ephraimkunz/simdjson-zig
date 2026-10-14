const std = @import("std");
const Io = std.Io;

const sj = @import("simdjson_zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const f = try std.Io.Dir.cwd().readFileAlloc(io, "large-file.json", init.gpa, .unlimited);
    defer gpa.free(f);

    const S = struct { type: []u8 };

    var iter = init.minimal.args.iterate();
    std.debug.assert(iter.skip());
    const run_stdlib = iter.next() orelse "0";
    if (std.mem.eql(u8, run_stdlib, "0")) {
        std.debug.print("Using stdlib\n", .{});
        const parsed = try std.json.parseFromSlice([]S, gpa, f, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        std.debug.print("{} items: {s}\n", .{ parsed.value.len, parsed.value[0].type });
    } else {
        std.debug.print("Using simdjson\n", .{});
        const parsed = try sj.parseFromSlice([]S, gpa, f, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        std.debug.print("{} items: {s}\n", .{ parsed.value.len, parsed.value[0].type });
    }
}
