const std = @import("std");
const TapeTokenSource = @import("tape.zig").TapeTokenSource;

/// This function matches the prototype of the [std.json.parseFromSlice](https://ziglang.org/documentation/master/std/#std.json.static.parseFromSlice) function,
/// allowing that function to be replaced seamlessly by this one. Note that this function uses more memory as it
/// parses the entire JSON file in memory up front, instead of walking it on demand.
pub fn parseFromSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    s: []const u8,
    options: std.json.ParseOptions,
) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    var tapeTokenSource = TapeTokenSource.init(s);
    defer tapeTokenSource.deinit();

    // For now, don't allow .alloc_if_needed in the options, as it makes us return a slice to the parser just
    // freed above in tapeTokenSource.deinit.
    var o = options;
    o.allocate = .alloc_always;

    return std.json.parseFromTokenSource(
        T,
        allocator,
        &tapeTokenSource,
        o,
    );
}

/// Parses the json document from s and returns the result. Allocations made during this operation are not carefully tracked and may not be possible to individually clean up. It is recommended to use a std.heap.ArenaAllocator or similar.
pub fn parseFromSliceLeaky(
    comptime T: type,
    allocator: std.mem.Allocator,
    s: []const u8,
    options: std.json.ParseOptions,
) std.json.ParseError(std.json.Scanner)!T {
    var tapeTokenSource = TapeTokenSource.init(s);
    defer tapeTokenSource.deinit();

    // For now, don't allow .alloc_if_needed in the options, as it makes us return a slice to the parser just
    // freed above in tapeTokenSource.deinit.
    var o = options;
    o.allocate = .alloc_always;

    return std.json.parseFromTokenSourceLeaky(
        T,
        allocator,
        &tapeTokenSource,
        o,
    );
}

test "parseFromSlice fails" {
    const source =
        \\ { "this is a test"  :
        \\ "value"        }
    ;
    const result = parseFromSlice(u32, std.testing.allocator, source, .{});
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, result);

    const stdlib_result = std.json.parseFromSlice(u32, std.testing.allocator, source, .{});
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, stdlib_result);
}

test "parseFromSlice fails 2" {
    const source =
        \\ { "this is a test"  :
        \\ value        }
    ;
    const result = parseFromSlice(u32, std.testing.allocator, source, .{});
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, result);

    const stdlib_result = std.json.parseFromSlice(u32, std.testing.allocator, source, .{});
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, stdlib_result);
}

test "parseFromSlice union" {
    const source = "{\"cat\": -3}";
    const U = union(enum) { dog: u32, cat: i5 };
    const result = try parseFromSlice(U, std.testing.allocator, source, .{});
    defer result.deinit();
    try std.testing.expectEqual(U{ .cat = -3 }, result.value);
}

test "parseFromSlice unescaped chars" {
    const source = "\"This is a test\n\"";

    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice([]u8, std.testing.allocator, source, .{}));
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, std.json.parseFromSlice([]u8, std.testing.allocator, source, .{}));
}

test "parseFromSlice unknown field" {
    const source = "{\"dinner\": \"spam\", \"lunch\": \"pbj\"}";

    const S = struct { dinner: []const u8 };
    const result = parseFromSlice(S, std.testing.allocator, source, .{});
    try std.testing.expectError(std.json.ParseFromValueError.UnknownField, result);
}

test "parseFromSlice ignores unknown field" {
    const source = "{\"dinner\": \"spam\", \"lunch\": \"pbj\"}";

    const S = struct { dinner: []const u8 };
    const result = try parseFromSlice(S, std.testing.allocator, source, .{ .ignore_unknown_fields = true });
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, "spam", result.value.dinner);
}

test "parseFromSlice alloc if needed" {
    const source = "{\"dinner\": \"spam\", \"lunch\": \"pbj\"}";

    const S = struct { dinner: []const u8, lunch: []const u8 };
    const result = try parseFromSlice(S, std.testing.allocator, source, .{ .allocate = .alloc_if_needed });
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, "spam", result.value.dinner);
    try std.testing.expectEqualSlices(u8, "pbj", result.value.lunch);
}

test "parseFromSlice positive number" {
    const source = "5";
    const result = try parseFromSlice(u32, std.testing.allocator, source, .{});
    defer result.deinit();
    try std.testing.expectEqual(5, result.value);
}

test "parseFromSlice negative number" {
    const source = "-5";
    const result = try parseFromSlice(i32, std.testing.allocator, source, .{});
    defer result.deinit();
    try std.testing.expectEqual(-5, result.value);
}

test "parseFromSlice float number" {
    const source = "-5.64";
    const result = try parseFromSlice(f64, std.testing.allocator, source, .{});
    defer result.deinit();
    try std.testing.expectEqual(-5.64, result.value);
}

test "parseFromSlice array" {
    const source = "[1, 2, 3, 4, 5]";
    const result = try parseFromSlice([]u8, std.testing.allocator, source, .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, result.value);
}

test "parseFromSlice struct" {
    const source =
        \\ { "dinner"  :
        \\ "food"        }
    ;

    const S = struct { dinner: []const u8 };
    const result = try parseFromSlice(S, std.testing.allocator, source, .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, "food", result.value.dinner);
}

test "parseFromSlice larger" {
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
    const result = try parseFromSlice(S, std.testing.allocator, source, .{ .ignore_unknown_fields = true });
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &.{5}, result.value.empty_structures.empty_array);
}

test "malformed: empty input" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice(u32, std.testing.allocator, "", .{}));
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, std.json.parseFromSlice(u32, std.testing.allocator, "", .{}));
}

test "malformed: truncated array" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice([]u32, std.testing.allocator, "[1,", .{}));
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, std.json.parseFromSlice([]u32, std.testing.allocator, "[1,", .{}));
}

test "malformed: unclosed string" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice([]const u8, std.testing.allocator, "\"abc", .{}));
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, std.json.parseFromSlice([]const u8, std.testing.allocator, "\"abc", .{}));
}

test "malformed: invalid utf-8 inside string" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice([]const u8, std.testing.allocator, "\"\xff\"", .{}));
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, std.json.parseFromSlice([]const u8, std.testing.allocator, "\"\xff\"", .{}));
}

test "malformed: bare invalid byte" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice(u32, std.testing.allocator, "\xff", .{}));
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, std.json.parseFromSlice(u32, std.testing.allocator, "\xff", .{}));
}

test "invalid escape -> string error" {
    const cases = [_][]const u8{
        "\"\\x\"", // unknown escape
        "\"\\u12G4\"", // non-hex digit
        "\"\\u12\"", // too few hex digits
        "\"\\ud800\"", // lone high surrogate
        "\"\\ud800\\u0041\"", // high surrogate + non-low surrogate
    };
    for (cases) |src| {
        const result = parseFromSlice([]const u8, std.testing.allocator, src, .{});
        try std.testing.expectError(std.json.Scanner.Error.SyntaxError, result);
        const result2 = std.json.parseFromSlice([]const u8, std.testing.allocator, src, .{});
        try std.testing.expectError(std.json.Scanner.Error.SyntaxError, result2);
    }

    const input = "{\"\\x\": 1}"; // bad escape in an object key
    const result = parseFromSlice([]const u8, std.testing.allocator, input, .{});
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, result);
    const result2 = std.json.parseFromSlice([]const u8, std.testing.allocator, input, .{});
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, result2);
}

test "malformed: balanced nesting beyond depth limit" {
    const depth = 2000;
    const buf = try std.testing.allocator.alloc(u8, depth * 2);
    defer std.testing.allocator.free(buf);
    @memset(buf[0..depth], '[');
    @memset(buf[depth..], ']');
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice(u32, std.testing.allocator, buf, .{}));
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, std.json.parseFromSlice(u32, std.testing.allocator, buf, .{}));
}

test "malformed: unbalanced nesting beyond depth limit" {
    const depth = 2000;
    const buf = try std.testing.allocator.alloc(u8, depth);
    defer std.testing.allocator.free(buf);
    @memset(buf, '[');
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice(u32, std.testing.allocator, buf, .{}));
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, std.json.parseFromSlice(u32, std.testing.allocator, buf, .{}));
}

test "bigint" {
    const val = try parseFromSlice(u128, std.testing.allocator, "99999999999999999999", .{});
    defer val.deinit();
    try std.testing.expectEqual(99999999999999999999, val.value);
    const val2 = try std.json.parseFromSlice(u128, std.testing.allocator, "99999999999999999999", .{});
    defer val2.deinit();
    try std.testing.expectEqual(99999999999999999999, val2.value);
}

test "malformed: number error" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice(u32, std.testing.allocator, "01234", .{}));
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, std.json.parseFromSlice(u32, std.testing.allocator, "01234", .{}));
}

test "malformed: incomplete null" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice(?u32, std.testing.allocator, "nul", .{}));
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, std.json.parseFromSlice(?u32, std.testing.allocator, "nul", .{}));
}

test "malformed: incomplete true" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice(?u32, std.testing.allocator, "tru", .{}));
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, std.json.parseFromSlice(?u32, std.testing.allocator, "tru", .{}));
}

test "malformed: incomplete false" {
    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, parseFromSlice(?u32, std.testing.allocator, "fals", .{}));
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, std.json.parseFromSlice(?u32, std.testing.allocator, "fals", .{}));
}

test "scientific notation" {
    const val = try parseFromSlice(f64, std.testing.allocator, "5e37", .{});
    defer val.deinit();
    try std.testing.expectEqual(5e37, val.value);
}

const Person = struct {
    name: []const u8,
    city: []const u8,
    tags: []const []const u8,
};

test "alloc_if_needed: result is independent of the input slice" {
    const input = try std.testing.allocator.dupe(u8, "{\"name\":\"n\",\"city\":\"c\",\"tags\":[\"t\"]}");
    const parsed = try parseFromSlice(Person, std.testing.allocator, input, .{
        .allocate = .alloc_if_needed,
    });
    defer parsed.deinit();

    @memset(input, 0xAA);
    std.testing.allocator.free(input);

    try std.testing.expectEqualStrings("n", parsed.value.name);
    try std.testing.expectEqualStrings("c", parsed.value.city);
    try std.testing.expectEqualStrings("t", parsed.value.tags[0]);
}

test "alloc_if_needed: repeated parses don't alias each other" {
    const first_source =
        \\{"name":"first-document-value","city":"A","tags":[]}
    ;
    const second_source =
        \\{"name":"second-document-val!","city":"B","tags":[]}
    ;

    const expected_first = try std.json.parseFromSlice(Person, std.testing.allocator, first_source, .{});
    defer expected_first.deinit();
    const expected_second = try std.json.parseFromSlice(Person, std.testing.allocator, second_source, .{});
    defer expected_second.deinit();

    const first = try parseFromSlice(Person, std.testing.allocator, first_source, .{ .allocate = .alloc_if_needed });
    defer first.deinit();

    const second = try parseFromSlice(Person, std.testing.allocator, second_source, .{ .allocate = .alloc_if_needed });
    defer second.deinit();

    try std.testing.expectEqualDeep(expected_first.value, first.value);
    try std.testing.expectEqualDeep(expected_second.value, second.value);
    try std.testing.expectEqualStrings("first-document-value", first.value.name);
    try std.testing.expectEqualStrings("second-document-val!", second.value.name);
}

test "slice leaky alloc_if_needed: result is independent of the input slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();
    const input = try allocator.dupe(u8, "{\"name\":\"n\",\"city\":\"c\",\"tags\":[\"t\"]}");
    const parsed = try parseFromSliceLeaky(Person, allocator, input, .{
        .allocate = .alloc_if_needed,
    });

    @memset(input, 0xAA);
    allocator.free(input);

    try std.testing.expectEqualStrings("n", parsed.name);
    try std.testing.expectEqualStrings("c", parsed.city);
    try std.testing.expectEqualStrings("t", parsed.tags[0]);
}

test "slice leaky alloc_if_needed: repeated parses don't alias each other" {
    const first_source =
        \\{"name":"first-document-value","city":"A","tags":[]}
    ;
    const second_source =
        \\{"name":"second-document-val!","city":"B","tags":[]}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expected_first = try std.json.parseFromSliceLeaky(Person, allocator, first_source, .{});
    const expected_second = try std.json.parseFromSliceLeaky(Person, allocator, second_source, .{});

    const first = try parseFromSliceLeaky(Person, allocator, first_source, .{ .allocate = .alloc_if_needed });
    const second = try parseFromSliceLeaky(Person, allocator, second_source, .{ .allocate = .alloc_if_needed });

    try std.testing.expectEqualDeep(expected_first, first);
    try std.testing.expectEqualDeep(expected_second, second);
    try std.testing.expectEqualStrings("first-document-value", first.name);
    try std.testing.expectEqualStrings("second-document-val!", second.name);
}

test "fuzz parseFromSlice" {
    const t = struct {
        var data: [1_000]u8 = undefined;
        fn fuzz_parseFromSlice(_: void, smith: *std.testing.Smith) !void {
            const len = smith.slice(&data);
            if (parseFromSlice(u8, std.testing.allocator, data[0..len], .{})) |p| {
                defer p.deinit();
            } else |_| {}
            if (parseFromSlice(bool, std.testing.allocator, data[0..len], .{})) |p| {
                defer p.deinit();
            } else |_| {}
            if (parseFromSlice([]u8, std.testing.allocator, data[0..len], .{})) |p| {
                defer p.deinit();
            } else |_| {}
            if (parseFromSlice([][]u8, std.testing.allocator, data[0..len], .{})) |p| {
                defer p.deinit();
            } else |_| {}

            const S = struct {
                @"test": [15]T,
                const T = struct {
                    f1: F,
                    f2: F,
                    const F = struct { size: ?i16 };
                };
            };
            if (parseFromSlice(S, std.testing.allocator, data[0..len], .{})) |p| {
                defer p.deinit();
            } else |_| {}

            if (parseFromSlice(union(enum) { a: u32, f: f64, l: bool }, std.testing.allocator, data[0..len], .{})) |p| {
                defer p.deinit();
            } else |_| {}
        }
    };
    try std.testing.fuzz({}, t.fuzz_parseFromSlice, .{});
}

test "fuzz parseFromSliceLeaky" {
    const t = struct {
        var data: [1_000]u8 = undefined;
        fn fuzz_parseFromSliceLeaky(_: void, smith: *std.testing.Smith) !void {
            const len = smith.slice(&data);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            _ = parseFromSliceLeaky(u8, allocator, data[0..len], .{}) catch {};
            _ = parseFromSliceLeaky(bool, allocator, data[0..len], .{}) catch {};
            _ = parseFromSliceLeaky([]u8, allocator, data[0..len], .{}) catch {};
            _ = parseFromSliceLeaky([][]u8, allocator, data[0..len], .{}) catch {};

            const S = struct {
                @"test": [15]T,
                const T = struct {
                    f1: F,
                    f2: F,
                    const F = struct { size: ?i16 };
                };
            };
            _ = parseFromSliceLeaky(S, allocator, data[0..len], .{}) catch {};

            _ = parseFromSliceLeaky(union(enum) { a: u32, f: f64, l: bool }, allocator, data[0..len], .{}) catch {};
        }
    };
    try std.testing.fuzz({}, t.fuzz_parseFromSliceLeaky, .{});
}

test "another large one" {
    const fixtures = @import("fixtures.zig");
    const result = try parseFromSlice(fixtures.Export, std.testing.allocator, fixtures.export_data, .{});
    defer result.deinit();
}

test "parseFromTokenSource" {
    const source =
        \\ { "dinner"  :
        \\ "food"        }
    ;

    const S = struct { dinner: []const u8 };
    var tapeTokenSource = TapeTokenSource.init(source);
    defer tapeTokenSource.deinit();

    const a = try std.json.parseFromTokenSource(
        S,
        std.testing.allocator,
        &tapeTokenSource,
        .{ .allocate = .alloc_if_needed },
    );

    // a is tied to the lifetime of tapeTokenSource and becomes invalid if the token source goes away.
    // If this is not desired, the options above should specify .allocate_always for the allocate parameter.
    try std.testing.expectEqualSlices(u8, "food", a.value.dinner);
    defer a.deinit();
}

test "parseFromTokenSourceLeaky" {
    const source =
        \\ { "dinner"  :
        \\ "food"        }
    ;

    const S = struct { dinner: []const u8 };
    var tapeTokenSource = TapeTokenSource.init(source);
    defer tapeTokenSource.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const a = try std.json.parseFromTokenSourceLeaky(
        S,
        allocator,
        &tapeTokenSource,
        .{ .allocate = .alloc_if_needed },
    );

    // a is tied to the lifetime of tapeTokenSource and becomes invalid if the token source goes away.
    // If this is not desired, the options above should specify .allocate_always for the allocate parameter.
    try std.testing.expectEqualSlices(u8, "food", a.dinner);
}

test "parse value" {
    const source = "100";

    var tapeTokenSource = TapeTokenSource.init(source);
    defer tapeTokenSource.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try std.json.Value.jsonParse(allocator, &tapeTokenSource, .{ .max_value_len = 50 });
    try std.testing.expectEqualDeep(std.json.Value{ .integer = 100 }, result);
}

test "parse array_hash_map" {
    const ahm = std.json.ArrayHashMap([]const u8);
    var source = TapeTokenSource.init("{\"test\": \"one\", \"test1\": \"two\", \"test2\": \"three\"}");
    var parsed = try ahm.jsonParse(std.testing.allocator, &source, .{ .allocate = .alloc_if_needed, .max_value_len = std.json.default_max_value_len });
    defer parsed.deinit(std.testing.allocator);

    var expected = try std.array_hash_map.String([]const u8).init(std.testing.allocator, &.{ "test", "test1", "test2" }, &.{ "one", "two", "three" });
    defer expected.deinit(std.testing.allocator);
    try std.testing.expect(try array_hash_maps_equal(expected, parsed.map));
}

fn array_hash_maps_equal(
    mapA: anytype,
    mapB: anytype,
) !bool {
    if (mapA.count() != mapB.count()) {
        return false;
    }

    var it = mapA.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const valA = entry.value_ptr.*;
        const valB = mapB.get(key) orelse return false;
        if (!std.mem.eql(u8, valA, valB)) {
            return false;
        }
    }

    return true;
}

// https://ziggit.dev/t/how-to-parse-arbitrary-json-data/1218/2
test "drop in for std.json 1" {
    const local = struct {
        fn parseAndVerify(comptime uses_stdlib: bool) !void {
            const json_string =
                \\ {
                \\   "a": true,
                \\   "b": 5,
                \\   "c": "okay"
                \\ }
            ;

            const parse = if (uses_stdlib) std.json.parseFromSlice else parseFromSlice;
            const parsed = try parse(std.json.Value, std.testing.allocator, json_string, .{});
            defer parsed.deinit();

            const a = parsed.value.object.get("a").?.bool;
            const b = parsed.value.object.get("b").?.integer;
            const c = parsed.value.object.get("c").?.string;
            try std.testing.expectEqual(true, a);
            try std.testing.expect(b == 5);
            try std.testing.expectEqualStrings("okay", c);
        }
    };

    try local.parseAndVerify(true);
    try local.parseAndVerify(false);
}

// https://medium.com/@mikecode/zig-how-to-parse-json-68f298e5e295
test "drop in for std.json 2" {
    const local = struct {
        fn parseAndVerify(comptime uses_stdlib: bool) !void {
            const Person2 = struct { name: []const u8, age: i32 };

            const json = "{\"name\": \"jim\" , \"age\": 20}";
            const allocator = std.testing.allocator;
            const parse = if (uses_stdlib) std.json.parseFromSlice else parseFromSlice;
            const parsed = try parse(Person2, allocator, json, .{});

            const person = parsed.value;
            defer parsed.deinit();

            const s = try allocator.print("name: {s} , age: {}\n", .{ person.name, person.age });
            defer allocator.free(s);
            try std.testing.expectEqualStrings("name: jim , age: 20\n", s);
        }
    };

    try local.parseAndVerify(true);
    try local.parseAndVerify(false);
}

test "drop in for std.json complex" {
    const local = struct {
        const Status = enum { pending, shipped, delivered };
        const Item = struct { sku: []const u8, qty: u32, price: f64, tags: []const []const u8 };
        const Payment = union(enum) {
            card: struct { last4: []const u8, brand: []const u8 },
            bank: struct { iban: []const u8 },
            cash: bool,
        };
        const Order = struct {
            id: u64,
            status: Status,
            customer: struct { name: []const u8, email: ?[]const u8, zip: ?[]const u8 = null },
            items: []const Item,
            payment: Payment,
            dims: [3]f32,
            priority: i8 = 0,
            attributes: std.json.ArrayHashMap([]const u8),
            meta: std.json.Value,
        };

        const json =
            \\{
            \\  "id": 18446744073709551615,
            \\  "status": "shipped",
            \\  "customer": { "name": "Zo\u00eb \"Z\"\tO'Brien \ud83d\ude00", "email": null, "zip": "84601" },
            \\  "items": [
            \\    { "sku": "A-100", "qty": 3, "price": 19.99, "tags": ["new", "sale"] },
            \\    { "sku": "B-200", "qty": 1, "price": 1.5e2, "tags": [] }
            \\  ],
            \\  "payment": { "card": { "last4": "4242", "brand": "visa" } },
            \\  "dims": [1.5, 2.25, 3],
            \\  "priority": -5,
            \\  "attributes": { "color": "red", "size": "L" },
            \\  "meta": { "gift": true, "wrap": { "layers": [1, 2, 3] }, "nothing": null },
            \\  "ignored": { "a": [1, 2, { "b": null }] }
            \\}
        ;

        fn parseAndVerify(comptime uses_stdlib: bool) !void {
            const allocator = std.testing.allocator;
            const parse = if (uses_stdlib) std.json.parseFromSlice else parseFromSlice;

            const parsed = try parse(Order, allocator, json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const o = parsed.value;

            try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), o.id);
            try std.testing.expectEqual(Status.shipped, o.status);
            try std.testing.expectEqualStrings("Zoë \"Z\"\tO'Brien 😀", o.customer.name);
            try std.testing.expect(o.customer.email == null);
            try std.testing.expectEqualStrings("84601", o.customer.zip.?);

            try std.testing.expectEqual(@as(usize, 2), o.items.len);
            try std.testing.expectEqualStrings("A-100", o.items[0].sku);
            try std.testing.expectApproxEqAbs(@as(f64, 19.99), o.items[0].price, 1e-9);
            try std.testing.expectEqualStrings("sale", o.items[0].tags[1]);
            try std.testing.expectApproxEqAbs(@as(f64, 150.0), o.items[1].price, 1e-9);
            try std.testing.expectEqual(@as(usize, 0), o.items[1].tags.len);

            try std.testing.expectEqualStrings("4242", o.payment.card.last4);
            try std.testing.expectEqualSlices(f32, &.{ 1.5, 2.25, 3.0 }, &o.dims);
            try std.testing.expectEqual(@as(i8, -5), o.priority);
            try std.testing.expectEqualStrings("L", o.attributes.map.get("size").?);

            try std.testing.expectEqual(true, o.meta.object.get("gift").?.bool);
            try std.testing.expect(o.meta.object.get("nothing").? == .null);
            const layers = o.meta.object.get("wrap").?.object.get("layers").?.array.items;
            try std.testing.expectEqual(@as(i64, 3), layers[2].integer);

            const s = try std.fmt.allocPrint(allocator, "{d}|{s}|{s}|{d}", .{ o.id, @tagName(o.status), o.items[0].sku, o.priority });
            defer allocator.free(s);
            try std.testing.expectEqualStrings("18446744073709551615|shipped|A-100|-5", s);
        }
    };

    try local.parseAndVerify(true);
    try local.parseAndVerify(false);
}

test "drop in for std.json errors" {
    const local = struct {
        const P = struct { name: []const u8, age: u8 };

        fn parseAndVerify(comptime uses_stdlib: bool) !void {
            const allocator = std.testing.allocator;
            const parse = if (uses_stdlib) std.json.parseFromSlice else parseFromSlice;

            try std.testing.expectError(error.MissingField, parse(P, allocator, "{\"name\":\"a\"}", .{}));
            try std.testing.expectError(error.UnknownField, parse(P, allocator, "{\"name\":\"a\",\"age\":1,\"x\":2}", .{}));
            try std.testing.expectError(error.DuplicateField, parse(P, allocator, "{\"name\":\"a\",\"name\":\"b\",\"age\":1}", .{}));

            try std.testing.expectError(error.InvalidCharacter, parse(P, allocator, "{\"name\":\"a\",\"age\":\"x\"}", .{}));

            try std.testing.expectError(error.Overflow, parse(P, allocator, "{\"name\":\"a\",\"age\":300}", .{}));
            try std.testing.expectError(error.SyntaxError, parse(P, allocator, "{\"name\":\"a\",\"age\":}", .{}));

            const expected_err = if (uses_stdlib) error.UnexpectedEndOfInput else error.SyntaxError;
            try std.testing.expectError(expected_err, parse(P, allocator, "{\"name\":\"a\",\"age\":1", .{}));
        }
    };

    try local.parseAndVerify(true);
    try local.parseAndVerify(false);
}
