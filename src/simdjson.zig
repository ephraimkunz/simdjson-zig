//! JSON parsing and stringification conforming to RFC 8259. https://datatracker.ietf.org/doc/html/rfc8259
//!
//! This Zig package is a binding on top of simdjson, the high performance C++ JSON parser. It attempts to be a
//! drop-in replacement for several parsing capabilities of the Zig standard library.
//!
//! The high-level `parseFromSlice` function deserializes a JSON document into a Zig type.
//! The `TapeTokenSource` can be used in any std.json functions that take a token source.
//! For additional control, the `TapeTokenSource` can be initialized with a TapeParser
//! that allows you to more efficiently parse multiple JSON documents and control memory
//! and nesting limits.
//! The `minify`, `validate`, and `validate_utf8` functions are SIMD-accelerated utilities.
//!
//! Parse into a dynamically-typed `Value` to load any JSON value for runtime inspection.
//!
const std = @import("std");

pub const parseFromSlice = @import("parse.zig").parseFromSlice;
pub const parseFromSliceLeaky = @import("parse.zig").parseFromSliceLeaky;

pub const TapeTokenSource = @import("tape.zig").TapeTokenSource;
pub const TapeParser = @import("tape.zig").TapeParser;

pub const minify = @import("minify.zig").minify;
pub const validate_utf8 = @import("validate.zig").validate_utf8;
pub const validate = @import("validate.zig").validate;

test {
    _ = @import("tape.zig");
    _ = @import("parse.zig");
    _ = @import("minify.zig");
    _ = @import("validate.zig");
}
