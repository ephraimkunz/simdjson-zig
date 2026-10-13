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

    const source =
        \\ { "this is a test"  :
        \\ "value"        }
    ;
    const result = try sj.parseFromSlice(u32, init.gpa, source, .{});
    std.debug.print("{}\n", .{result});
}
