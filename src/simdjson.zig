//! JSON parsing and stringification conforming to RFC 8259. https://datatracker.ietf.org/doc/html/rfc8259
//!
//! This library is a binding on top of simdjson, the high performance C++ JSON parser. It attempts to be a
//! drop-in replacement for several parsing capabilities of the Zig standard library.
//!
//! The high-level `parseFromSlice` function deserializes a JSON document into a Zig type.
//! The `TapeTokenSource` can be used in any std.json functions that take a token source.
//! The `minify` and `validate_utf8` functions are SIMD-accelerated utilities.
//!
//! Parse into a dynamically-typed `Value` to load any JSON value for runtime inspection.
//!
const std = @import("std");

pub const parseFromSlice = @import("toplevelfunctions.zig").parseFromSlice;
pub const parseFromSliceLeaky = @import("toplevelfunctions.zig").parseFromSliceLeaky;

pub const TapeTokenSource = @import("tapetokensource.zig").TapeTokenSource;
pub const TapeParser = @import("tapetokensource.zig").TapeParser;

pub const minify = @import("minify.zig").minify;
pub const validate_utf8 = @import("validateUTF8.zig").validate_utf8;

test {
    _ = @import("tapetokensource.zig");
    _ = @import("toplevelfunctions.zig");
    _ = @import("minify.zig");
    _ = @import("validateUTF8.zig");
}
