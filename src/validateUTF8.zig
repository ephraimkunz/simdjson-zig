const std = @import("std");
const sj = @import("simdjson");

pub fn validate_utf8(str: []const u8) bool {
    return sj.sj_validate_utf8(str.ptr, str.len);
}

test validate_utf8 {
    try std.testing.expect(validate_utf8("this is a test"));
}

test "validate_utf8 invalid" {
    try std.testing.expect(!validate_utf8("Hello \xff World"));
}

test "fuzz validateUTF8" {
    const t = struct {
        var data: [1_000]u8 = undefined;
        fn fuzz_validateUTF8(_: void, smith: *std.testing.Smith) !void {
            const len = smith.slice(&data);
            _ = validate_utf8(data[0..len]);
        }
    };
    try std.testing.fuzz({}, t.fuzz_validateUTF8, .{});
}
