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

// Matches std.json.parseFromSlice exactly as it's a drop-in replacement
pub fn parseFromSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    s: []const u8,
    options: std.json.ParseOptions,
) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    _ = allocator;
    _ = options;
    const parser = sj.sj_parser_new();
    defer sj.sj_parser_free(parser);

    check(sj.sj_parser_parse(parser, s.ptr, s.len)) catch |e| {
        std.debug.print("{}\n", .{e});
        return std.json.ParseFromValueError.InvalidCharacter;
    };
    const tape = sj.sj_parser_get_tape_view(parser);
    if (tape.tape_ptr == null or tape.tape_len == 0) {
        return std.json.ParseFromValueError.MissingField;
    }

    const tape_slice = tape.tape_ptr[0..tape.tape_len];

    std.debug.print("{d}\n", .{tape_slice[0] & 0x00ffffffffffffff});

    return std.json.ParseFromValueError.DuplicateField;
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

test parseFromSlice {
    const source =
        \\ { "this is a test"  :
        \\ "value"        }
    ;
    const result = parseFromSlice(u32, std.testing.allocator, source, .{});
    try std.testing.expectError(std.json.ParseFromValueError.DuplicateField, result);
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
