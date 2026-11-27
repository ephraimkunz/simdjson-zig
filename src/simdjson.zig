//! This Zig package is a binding for [simdjson](https://github.com/simdjson/simdjson), the high performance C++ JSON parser, to be used from Zig. It attempts to be a
//! drop-in replacement for several JSON parsing capabilities of the Zig standard library.
//!
//! The high-level `parseFromSlice` and `parseFromSliceLeaky` functions deserialize a JSON document into a Zig type, and are drop-in
//! replacements for the std.json functions of the same name.
//! The `validate` function is also a drop-in replacement for the `std.json.validate` function.
//!
//! "Drop-in" as used above means:
//! * `parseFromSlice`, `parseFromSliceLeaky` and `validate` have the same signatures and error sets as the std.json functions of the same name, so a call to the
//!   std.json function can be replaced by a call to the function here and continue to compile. The rest of std.json (`ParseOptions`, `Parsed`, `Value`, `Stringify`, etc)
//!   is not re-exported, so keep importing those from `std.json`.
//! * `TapeTokenSource` can be passed to any std.json function that takes a token source, and that function then has the same error set as when it is given a `std.json.Scanner`.
//!
//! Note that memory usage might change (it's usually higher with simdjson) as well as performance (it's usually higher with simdjson). Furthermore, while the drop-in replacements have the same error sets as the std library functions,
//! different errors from those sets may be returned from simdjson and the stdlib for a given JSON document, due to an inexact mapping between simdjson errors and stdlib errors and internal differences around when parsing steps happen.
//!
//! Numeric behavior follows simdjson's [tape](https://github.com/simdjson/simdjson/blob/master/doc/tape.md) representation. Decimal and exponent forms are converted to `f64` before conversion to the
//! requested Zig type, which can reduce precision or affect integer conversion, including when setting `parse_numbers = false` in [ParseOptions](https://ziglang.org/documentation/master/std/#std.json.static.ParseOptions). Numbers outside
//! the finite `f64` range may be rejected. Large integer literals without a decimal point or exponent are preserved as text through
//! [bigint](https://github.com/simdjson/simdjson/blob/master/doc/tape.md#big-integers) support. Original numeric spelling and negative zero are not always preserved.
//!
//! In addition to the drop-in functions above, this package exposes simd-accelerated `validateUTF8` and `minify` functions.
//!
//! For lower-level control, the `TapeTokenSource` can be used directly or passed into any std.json functions that take a token source, such as `std.json.parseFromTokenSource`.
//! For additional control, the TapeTokenSource can be initialized with a `TapeParser`
//! that allows you to more efficiently parse multiple JSON documents (by reusing the same TapeParser) and control memory
//! and nesting limits.
//!
//! Parse into a dynamically-typed `std.json.Value` to load any JSON value for runtime inspection.
//!
//! ## Lifetimes
//! The lifetime of a parsed object depends on if alloc_always or alloc_if_needed is passed to ParseOptions.allocate.
//!
//! If alloc_if_needed is passed, the lifetime of a parsed object is tied to TapeParser. That means that a parsed object should not outlive the TapeParser that created it (the parser shouldn't be reused or deallocated while its objects are alive). This differs from std.json.Scanner / Reader's lifetime, which is tied to the input slice if alloc_if_needed is passed.
//!
//! If alloc_always is passed, the lifetime of the parsed object is tied to the arena returned by std.json.Parsed.
//!
//! `parseFromSlice` and `parseFromSliceLeaky` internally use a TapeParser instance that is allocated and deallocated before the functions return, so they force alloc_always internally.
//!
//! Similar to std.json.Scanner/ Reader, simdjson-zig's TapeTokenSource should not be reused after a parse completes. Parsing the input slice is lazy: TapeTokenSource.init and TapeTokenSource.initWithParser only store the passed-in slice, and the document is parsed on the first token or peek. The input slice must not be freed or modified between init() and the end of parsing.
//!

const std = @import("std");

pub const parseFromSlice = @import("parse.zig").parseFromSlice;
pub const parseFromSliceLeaky = @import("parse.zig").parseFromSliceLeaky;

pub const TapeTokenSourceError = @import("tape.zig").TapeTokenSourceError;
pub const TapeTokenSource = @import("tape.zig").TapeTokenSource;

pub const TapeParserError = @import("tape.zig").TapeParserError;
pub const TapeParser = @import("tape.zig").TapeParser;

pub const MinifyError = @import("minify.zig").MinifyError;
pub const minify = @import("minify.zig").minify;

pub const validateUTF8 = @import("validate.zig").validateUTF8;
pub const validate = @import("validate.zig").validate;

test {
    _ = @import("tape.zig");
    _ = @import("parse.zig");
    _ = @import("minify.zig");
    _ = @import("validate.zig");
    _ = @import("test.zig");
    _ = @import("JSONTestSuite_test.zig");
    _ = @import("fixtures.zig");
    _ = @import("error.zig");
}

test "signatures and error sets match std.json" {
    const Scanner = std.json.Scanner;
    try std.testing.expect(std.json.ParseError(TapeTokenSource) == std.json.ParseError(Scanner));

    const allocator = std.testing.allocator;
    inline for (.{ u8, []const u8, ?bool, std.json.Value, struct { x: f64 } }) |T| {
        try std.testing.expect(@TypeOf(parseFromSlice(T, allocator, "", .{})) == @TypeOf(std.json.parseFromSlice(T, allocator, "", .{})));
        try std.testing.expect(@TypeOf(parseFromSliceLeaky(T, allocator, "", .{})) == @TypeOf(std.json.parseFromSliceLeaky(T, allocator, "", .{})));
    }
    try std.testing.expect(@TypeOf(validate) == @TypeOf(std.json.validate));
}
