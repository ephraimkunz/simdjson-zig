const std = @import("std");
const sj = @import("simdjson_c");

const err = @import("error.zig");

pub const MinifyError = error{
    /// missing quote at the end
    UnclosedString,
    /// out_buf is shorter than str
    InvalidArg,
    /// simdjson returned an unexpected error
    Unknown,
};

/// Minify a string (remove all unnecessary spaces).
/// This function does not validate your content, and it does not parse it.
/// It is much faster than parsing the string and re-serializing it in minified form.
/// The output slice should point to a valid memory region that is as large as the input slice.
/// Returns a slice of `out_buf` starting at index 0 containing the result.
pub fn minify(str: []const u8, out_buf: []u8) MinifyError![]u8 {
    if (out_buf.len < str.len) {
        return MinifyError.InvalidArg;
    }

    var length: usize = 0;
    const err_code = sj.sj_minify(str.ptr, str.len, out_buf.ptr, &length);
    err.check(err_code) catch |e| {
        return switch (e) {
            error.UnclosedString => MinifyError.UnclosedString,
            else => MinifyError.Unknown,
        };
    };
    return out_buf[0..length];
}

test minify {
    const source =
        \\ { "this is a test"  :
        \\ "value"        }
    ;
    var out: [source.len]u8 = undefined;
    const result = try minify(source, &out);
    try std.testing.expectEqualSlices(u8, result, "{\"this is a test\":\"value\"}");
}

test "minify empty" {
    var out: [0]u8 = undefined;
    const count = try minify(&.{}, &out);
    try std.testing.expectEqual(0, count.len);
}

test "minify too small output buffer" {
    const source =
        \\ { "this is a test"  :
        \\ "value"        }
    ;
    var out: [0]u8 = undefined;
    const result = minify(source, &out);
    try std.testing.expectError(MinifyError.InvalidArg, result);
}

test "minify unterminated" {
    const source = "\"this is a test";
    var out: [source.len]u8 = undefined;
    const result = minify(source, &out);
    try std.testing.expectError(MinifyError.UnclosedString, result);
}

test "fuzz minify" {
    const t = struct {
        var input: [1_000]u8 = undefined;
        var output: [1_000]u8 = undefined;
        fn fuzz_minify(_: void, smith: *std.testing.Smith) !void {
            const in_len = smith.slice(&input);
            const out_len = smith.slice(&output);
            _ = minify(input[0..in_len], output[0..out_len]) catch {};
        }
    };
    try std.testing.fuzz({}, t.fuzz_minify, .{});
}
