const std = @import("std");
const sj = @import("simdjson_c");
const TapeParser = @import("tape.zig").TapeParser;
const err = @import("error.zig");

/// The UTF-8 validation function merely checks that the input is valid UTF-8: it works with strings in general, not just JSON strings.
pub fn validate_utf8(s: []const u8) bool {
    return sj.sj_validate_utf8(s.ptr, s.len);
}

/// Scan the input and check for malformed JSON.
pub fn validate(s: []const u8) bool {
    const parser = TapeParser.init(.{});
    defer parser.deinit();
    err.check(sj.sj_parser_parse(parser.inner, s.ptr, s.len)) catch return false;
    return true;
}

test validate_utf8 {
    try std.testing.expect(validate_utf8("this is a test"));
}

test "validate_utf8 invalid" {
    try std.testing.expect(!validate_utf8("Hello \xff World"));
}

test validate {
    const bad_json = "{{5}}";
    try std.testing.expect(!validate(bad_json));

    const good_json = "{\"a\": {\"good\": 5.34}}";
    try std.testing.expect(validate(good_json));
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
