const std = @import("std");
const sj = @import("simdjson_c");
const TapeParser = @import("tape.zig").TapeParser;
const err = @import("error.zig");

/// The UTF-8 validation function merely checks that the input is valid UTF-8: it works with strings in general, not just JSON strings.
pub fn validateUTF8(s: []const u8) bool {
    return sj.sj_validate_utf8(s.ptr, s.len);
}

/// This function matches the prototype of the [std.json.validate](https://ziglang.org/documentation/master/std/#std.json.Scanner.validate) function,
/// allowing that function to be replaced seamlessly by this one.
///
/// Scan the input and check for malformed JSON.
/// Returns `error.OutOfMemory` if allocation fails or the input is too large.
pub fn validate(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error!bool {
    _ = allocator;
    const parser = TapeParser.init(.{}) catch |e| {
        switch (e) {
            error.MemAlloc, error.Capacity => return error.OutOfMemory,
            else => return false,
        }
    };
    defer parser.deinit();
    err.check(sj.sj_parser_parse(parser.inner, s.ptr, s.len, parser.zero_copy)) catch |e| {
        switch (e) {
            error.MemAlloc, error.Capacity => return error.OutOfMemory,
            else => return false,
        }
    };
    return true;
}

test validateUTF8 {
    try std.testing.expect(validateUTF8("this is a test"));
}

test "validate_utf8 invalid" {
    try std.testing.expect(!validateUTF8("Hello \xff World"));
}

test validate {
    const bad_json = "{{5}}";
    try std.testing.expect(!try validate(std.testing.allocator, bad_json));

    const good_json = "{\"a\": {\"good\": 5.34}}";
    try std.testing.expect(try validate(std.testing.allocator, good_json));
}

test "drop-in validate" {
    const local = struct {
        const bad_json = "{{5}}";
        const good_json = "{\"a\": {\"good\": 5.34}}";

        fn validateAndVerify(comptime uses_stdlib: bool) !void {
            const v = if (uses_stdlib) std.json.validate else validate;

            try std.testing.expect(!try v(std.testing.allocator, bad_json));
            try std.testing.expect(try v(std.testing.allocator, good_json));
        }
    };

    try local.validateAndVerify(true);
    try local.validateAndVerify(false);
}

test "fuzz validateUTF8" {
    const t = struct {
        var data: [1_000]u8 = undefined;
        fn fuzz_validateUTF8(_: void, smith: *std.testing.Smith) !void {
            const len = smith.slice(&data);
            _ = validateUTF8(data[0..len]);
        }
    };
    try std.testing.fuzz({}, t.fuzz_validateUTF8, .{});
}

test "fuzz validate" {
    const t = struct {
        var data: [1_000]u8 = undefined;
        fn fuzz_validate(_: void, smith: *std.testing.Smith) !void {
            const len = smith.slice(&data);
            _ = validate(std.testing.allocator, data[0..len]) catch {};
        }
    };
    try std.testing.fuzz({}, t.fuzz_validate, .{});
}
