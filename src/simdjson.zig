//! This Zig package is a binding for [simdjson](https://github.com/simdjson/simdjson), the high performance C++ JSON parser, to be used from Zig. It attempts to be a
//! drop-in replacement for several JSON parsing capabilities of the Zig standard library.
//!
//! The high-level `parseFromSlice` and `parseFromSliceLeaky` functions deserialize a JSON document into a Zig type, and are drop-in
//! replacements for the std.json functions of the same name.
//! The `validate` function is also a drop-in replacement for the `std.json.validate` function.
//!
//! "Drop-in" as used above means "same API", such that a `const json = @import("std").json` statement could be swapped for `const json = @import("simdjson")` and would continue to compile and function properly.
//! Note that memory usage might change (it's usually higher with simdjson) as well as performance (it's usually higher with simdjson). Furthermore, while the drop-in replacements have the same error sets as the std library functions,
//! different errors from those sets may be returned from simdjson and the stdlib for a given JSON document, due to an inexact mapping between simdjson errors and stdlib errors and internal differences around when parsing steps happen.
//!
//! In addition to the drop-in functions above, this package exposes simd-accelerated `validateUTF8` and `minify` functions.
//!
//! For lower-level control, the `TapeTokenSource` can be used directly or passed into any std.json functions that take a token source, such as `std.json.parseFromTokenSource`.
//! For additional control, the TapeTokenSource can be initialized with a `TapeParser`
//! that allows you to more efficiently parse multiple JSON documents (by reusing the same TapeParser) and control memory
//! and nesting limits.
//!
//! Parse into a dynamically-typed `Value` to load any JSON value for runtime inspection.
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
}
