const std = @import("std");
const sj = @import("simdjson");

pub const Error = error{
    Capacity,
    MemAlloc,
    TapeError,
    DepthError,
    StringError,
    TAtomError,
    FAtomError,
    NAtomError,
    NumberError,
    BigIntError,
    Utf8Error,
    Uninitialized,
    Empty,
    UnescapedChars,
    UnclosedString,
    UnsupportedArchitecture,
    IncorrectType,
    NumberOutOfRange,
    IndexOutOfBounds,
    NoSuchField,
    IoError,
    InvalidJsonPointer,
    InvalidUriFragment,
    UnexpectedError,
    ParserInUse,
    OutOfOrderIteration,
    InsufficientPadding,
    IncompleteArrayOrObject,
    ScalarDocumentAsValue,
    OutOfBounds,
    TrailingContent,
    OutOfCapacity,
    UnknownField,
    /// Code we don't recognize (newer simdjson than the binding)
    Unknown,
};

const Token = std.json.Token;
const TokenType = std.json.TokenType;
const JSON_VALUE_MASK: u64 = 0x00FFFFFFFFFFFFFF;

pub const TapeTokenSource = struct {
    tape: Tape,
    pos: usize = 1, // Skip the first r entry.
    gpa: std.mem.Allocator,
    pub const NextError = error{UnknownTapeEntry} || std.mem.Allocator.Error;
    pub const PeekError = error{UnknownTapeEntry};
    pub const SkipError = error{};
    pub const AllocError = NextError;

    pub fn peekNextTokenType(self: *TapeTokenSource) TapeTokenSource.PeekError!TokenType {
        const val = self.tape.tape[self.pos];
        switch (val >> 56) {
            'n' => return TokenType.null,
            't' => return TokenType.true,
            'f' => return TokenType.false,
            '[' => return TokenType.array_begin,
            ']' => return TokenType.array_end,
            '{' => return TokenType.object_begin,
            '}' => return TokenType.object_end,
            'r' => return TokenType.end_of_document,
            '"' => return TokenType.string,
            'l', 'u', 'd' => return TokenType.number,
            else => return PeekError.UnknownTapeEntry,
        }
    }

    pub fn skipValue(self: *TapeTokenSource) TapeTokenSource.SkipError!void {
        const val = self.tape.tape[self.pos];
        self.pos += 1;

        switch (val >> 56) {
            'l', 'u', 'd' => self.pos += 1,
            '[', '{' => {
                const x = val & 0x00000000ffffffff;
                self.pos = x;
            },
            else => {},
        }

        return {};
    }

    pub fn next(self: *TapeTokenSource) TapeTokenSource.NextError!std.json.Token {
        return self.next_internal(self.gpa, .alloc_if_needed);
    }

    /// https://ziglang.org/documentation/master/std/#std.json.Scanner.Token
    pub fn nextAllocMax(self: *TapeTokenSource, allocator: std.mem.Allocator, when: std.json.AllocWhen, max_value_len: usize) TapeTokenSource.AllocError!Token {
        _ = max_value_len;
        return self.next_internal(allocator, when);
    }

    pub fn deinit(self: *TapeTokenSource) void {
        _ = self;
    }

    fn next_internal(
        self: *TapeTokenSource,
        allocator: std.mem.Allocator,
        when: std.json.AllocWhen,
    ) TapeTokenSource.NextError!std.json.Token {
        if (self.pos >= self.tape.tape.len) {
            return Token.end_of_document;
        }
        const val = self.tape.tape[self.pos];
        self.pos += 1;
        switch (val >> 56) {
            'n' => return Token.null,
            't' => return Token.true,
            'f' => return Token.false,
            '[' => return Token.array_begin,
            ']' => return Token.array_end,
            '{' => return Token.object_begin,
            '}' => return Token.object_end,
            'r' => return Token.end_of_document,
            '"' => {
                const index = JSON_VALUE_MASK & val;
                const len = std.mem.readInt(u32, self.tape.string_buf[index .. index + 4][0..4], .little);
                const s = self.tape.string_buf[index + 4 .. index + 4 + len];

                switch (when) {
                    .alloc_always => return Token{ .allocated_string = try allocator.dupe(u8, s) },
                    .alloc_if_needed => return Token{ .string = s },
                }
            },
            'l' => {
                // Any way we can get around always allocating here? I don't think it meets the contract for next().
                const num: i64 = @bitCast(self.tape.tape[self.pos]);
                const num_str = try allocator.print("{}", .{num});
                const result = Token{ .allocated_number = num_str };
                self.pos += 1;
                return result;
            },
            'u' => {
                // Any way we can get around always allocating here? I don't think it meets the contract for next().
                const num: u64 = @bitCast(self.tape.tape[self.pos]);
                const num_str = try allocator.print("{}", .{num});
                const result = Token{ .allocated_number = num_str };
                self.pos += 1;
                return result;
            },
            'd' => {
                // Any way we can get around always allocating here? I don't think it meets the contract for next().
                const num: f64 = @bitCast(self.tape.tape[self.pos]);
                const num_str = try allocator.print("{}", .{num});
                const result = Token{ .allocated_number = num_str };
                self.pos += 1;
                return result;
            },
            else => return NextError.UnknownTapeEntry,
        }
        unreachable;
    }
};

// Matches std.json.parseFromSlice exactly as it's a drop-in replacement
pub fn parseFromSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    s: []const u8,
    options: std.json.ParseOptions,
) std.json.ParseError(TapeTokenSource)!std.json.Parsed(T) {
    const parser = sj.sj_parser_new();
    defer sj.sj_parser_free(parser);

    check(sj.sj_parser_parse(parser, s.ptr, s.len)) catch |e| {
        switch (e) {
            Error.TapeError => return std.json.ParseFromValueError.UnexpectedToken,
            else => unreachable,
        }
    };
    const c_tape = sj.sj_parser_get_tape_view(parser);
    const tape = Tape.init(c_tape);

    var tapeTokenSource = TapeTokenSource{ .tape = tape, .gpa = allocator };
    defer tapeTokenSource.deinit();

    return std.json.parseFromTokenSource(
        T,
        allocator,
        &tapeTokenSource,
        options,
    );
}

pub fn minify(str: []const u8, out_buf: []u8) Error!usize {
    if (out_buf.len < str.len) {
        return Error.Capacity;
    }

    var length: usize = 0;
    const err_code = sj.sj_minify(str.ptr, str.len, out_buf.ptr, &length);
    try check(err_code);
    return length;
}

pub fn validate_utf8(str: []const u8) bool {
    return sj.sj_validate_utf8(str.ptr, str.len);
}

const Tape = struct {
    tape: []u64,
    string_buf: []u8,

    fn init(c_tape: sj.sj_tape) Tape {
        return .{ .tape = c_tape.tape_ptr[0..c_tape.tape_len], .string_buf = c_tape.string_buf_ptr[0..c_tape.string_buf_len] };
    }
};

/// Mirrors simdjson::error_code. Values must match the C++ header.
const ErrorCode = enum(c_int) {
    success = 0,
    capacity,
    memalloc,
    tape_error,
    depth_error,
    string_error,
    t_atom_error,
    f_atom_error,
    n_atom_error,
    number_error,
    bigint_error,
    utf8_error,
    uninitialized,
    empty,
    unescaped_chars,
    unclosed_string,
    unsupported_architecture,
    incorrect_type,
    number_out_of_range,
    index_out_of_bounds,
    no_such_field,
    io_error,
    invalid_json_pointer,
    invalid_uri_fragment,
    unexpected_error,
    parser_in_use,
    out_of_order_iteration,
    insufficient_padding,
    incomplete_array_or_object,
    scalar_document_as_value,
    out_of_bounds,
    trailing_content,
    out_of_capacity,
    unknown_field,
    _,
};

fn check(code: c_int) Error!void {
    const error_code: ErrorCode = @fromBackingInt(@intCast(code));
    return switch (error_code) {
        .success => {},
        .capacity => error.Capacity,
        .memalloc => error.MemAlloc,
        .tape_error => error.TapeError,
        .depth_error => error.DepthError,
        .string_error => error.StringError,
        .t_atom_error => error.TAtomError,
        .f_atom_error => error.FAtomError,
        .n_atom_error => error.NAtomError,
        .number_error => error.NumberError,
        .bigint_error => error.BigIntError,
        .utf8_error => error.Utf8Error,
        .uninitialized => error.Uninitialized,
        .empty => error.Empty,
        .unescaped_chars => error.UnescapedChars,
        .unclosed_string => error.UnclosedString,
        .unsupported_architecture => error.UnsupportedArchitecture,
        .incorrect_type => error.IncorrectType,
        .number_out_of_range => error.NumberOutOfRange,
        .index_out_of_bounds => error.IndexOutOfBounds,
        .no_such_field => error.NoSuchField,
        .io_error => error.IoError,
        .invalid_json_pointer => error.InvalidJsonPointer,
        .invalid_uri_fragment => error.InvalidUriFragment,
        .unexpected_error => error.UnexpectedError,
        .parser_in_use => error.ParserInUse,
        .out_of_order_iteration => error.OutOfOrderIteration,
        .insufficient_padding => error.InsufficientPadding,
        .incomplete_array_or_object => error.IncompleteArrayOrObject,
        .scalar_document_as_value => error.ScalarDocumentAsValue,
        .out_of_bounds => error.OutOfBounds,
        .trailing_content => error.TrailingContent,
        .out_of_capacity => error.OutOfCapacity,
        .unknown_field => error.UnknownField,
        _ => error.Unknown,
    };
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
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, result);

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
    try std.testing.expectError(Error.Capacity, count);
}

test "minify unterminated" {
    const source = "\"this is a test";
    var out: [source.len]u8 = undefined;
    const count = minify(source, &out);
    try std.testing.expectError(Error.UnclosedString, count);
}

test validate_utf8 {
    try std.testing.expect(validate_utf8("this is a test"));
}

test "validate_utf8 invalid" {
    try std.testing.expect(!validate_utf8("Hello \xff World"));
}
