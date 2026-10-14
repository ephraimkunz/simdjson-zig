const std = @import("std");
const sj = @import("simdjson");

const err = @import("error.zig");

pub fn minify(str: []const u8, out_buf: []u8) err.Error!usize {
    if (out_buf.len < str.len) {
        return err.Error.Capacity;
    }

    var length: usize = 0;
    const err_code = sj.sj_minify(str.ptr, str.len, out_buf.ptr, &length);
    try err.check(err_code);
    return length;
}

test minify {
    const source =
        \\ { "this is a test"  :
        \\ "value"        }
    ;
    var out: [source.len]u8 = undefined;
    const count = try minify(source, &out);
    try std.testing.expectEqualSlices(u8, out[0..count], "{\"this is a test\":\"value\"}");
}

test "minify empty" {
    var out: [0]u8 = undefined;
    const count = minify(&.{}, &out);
    try std.testing.expectEqual(0, count);
}

test "minify too small output buffer" {
    const source =
        \\ { "this is a test"  :
        \\ "value"        }
    ;
    var out: [0]u8 = undefined;
    const count = minify(source, &out);
    try std.testing.expectError(err.Error.Capacity, count);
}

test "minify unterminated" {
    const source = "\"this is a test";
    var out: [source.len]u8 = undefined;
    const count = minify(source, &out);
    try std.testing.expectError(err.Error.UnclosedString, count);
}

test "fuzz minify" {
    const t = struct {
        var input: [1_000_000_000]u8 = undefined;
        var output: [1_000_000_000]u8 = undefined;
        fn fuzz_minify(_: void, smith: *std.testing.Smith) !void {
            const in_len = smith.slice(&input);
            const out_len = smith.slice(&output);
            _ = minify(input[0..in_len], output[0..out_len]) catch {};
        }
    };
    try std.testing.fuzz({}, t.fuzz_minify, .{});
}
