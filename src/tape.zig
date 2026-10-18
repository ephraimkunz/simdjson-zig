const std = @import("std");
const sj = @import("simdjson_c");
const err = @import("error.zig");

const Token = std.json.Token;
const TokenType = std.json.TokenType;

/// This is the lower-level parser that TapeTokenSource actually reads from. If you are parsing many JSON documents, it's more efficient to construct
/// the parser once and reuse it for each parse by passing it to TapeTokenSource, than to reconstruct it each time.
/// Using TapeParser with the TapeTokenSource also allows you to customize parser behavior with options.
/// Using TapeTokenSource without an explicit TapeParser is the same as using it with one with default Options, and no reuse-between calls.
pub const TapeParser = struct {
    inner: ?*sj.sj_parser,
    zero_copy: bool,

    pub const Options = struct {
        /// This is the largest document this parser can automatically support.
        /// The parser may reallocate internal buffers as needed up to this amount as documents are passed to it.
        /// There's an implementation-defined limit to the smallest this can get which will be set if you set too small.
        /// The default used here is what the simdjson library uses as a default.
        max_capacity: usize = 0xFFFFFFFF,

        /// The maximum depth of this parser (the most deeply nested objects and arrays it can process).
        /// The default used here is what the simdjson library uses as a default.
        max_depth: usize = 1024,

        /// If zero_copy is set, performance may be slower but more memory efficient, since the buffer isn't copied and
        /// padded internally when parsing. Otherwise, performance may be faster but may use more memory. Speed and memory
        /// use depend on the size of the file being parsed, and sometimes zero_copy may be preferable.
        /// See https://github.com/simdjson/simdjson/blob/master/doc/dom.md#parsing-without-padding
        zero_copy: bool = true,
    };

    pub fn init(options: Options) TapeParser {
        return .{ .inner = sj.sj_parser_new(options.max_capacity, options.max_depth), .zero_copy = options.zero_copy };
    }

    pub fn deinit(self: TapeParser) void {
        sj.sj_parser_free(self.inner);
    }
};

// https://github.com/simdjson/simdjson/blob/master/doc/tape.md
/// This is a token source that can be passed into any function in [the std lib json namespace](https://ziglang.org/documentation/master/std/#std.json)
/// that takes a generic source (a std.json.Reader or std.json.Scanner): [parseFromTokenSource](https://ziglang.org/documentation/master/std/#std.json.static.parseFromTokenSource), [parseFromTokenSourceLeaky](https://ziglang.org/documentation/master/std/#std.json.static.parseFromTokenSource), etc.
pub const TapeTokenSource = struct {
    s: []const u8,
    pos: usize = 1, // Skip the first r entry.
    // Used to temporarily store stringified numbers returned by reference, since they are already parsed in the tape but
    // std.json expects them non-parsed. I think 24 is the max for a 64 bit double literal, but go a little big just in case :)
    // The contract is that .next() can return a slice that will only last until it's called again.
    scratch: [30]u8 = undefined,

    // Externally built, mutually exclusive with the lazily created cached_parser below. But still will use cached_tape that's lazily created.
    parser: ?TapeParser = null,

    // Built once on demand, cached for future use until deinit.
    cached_tape: ?Tape = null,
    cached_parser: ?*sj.sj_parser = null,

    pub const NextError = std.json.Scanner.NextError;
    pub const PeekError = std.json.Scanner.PeekError;
    pub const SkipError = std.json.Scanner.SkipError;
    pub const AllocError = std.json.Scanner.AllocError;

    /// Use this function for convenience when only parsing one document.
    pub fn init(s: []const u8) TapeTokenSource {
        return .{ .s = s };
    }

    /// When parsing multiple documents, it's more efficient to reuse the parser, creating a
    /// new TapeTokenSource for each document but passing in the same parser.
    pub fn initWithParser(s: []const u8, parser: TapeParser) TapeTokenSource {
        return .{ .s = s, .parser = parser };
    }

    fn tape(self: *TapeTokenSource) std.json.Scanner.Error!Tape {
        return self.cached_tape orelse self.parseAndCacheTape();
    }

    /// Just for testing, so we don't have to keep creating these.
    fn reset(self: *TapeTokenSource) void {
        self.pos = 1;
    }

    fn parseAndCacheTape(self: *TapeTokenSource) std.json.Scanner.Error!Tape {
        const has_user_provided_parser = self.parser != null;
        const options = TapeParser.Options{};
        const parser = if (self.parser) |p| p.inner else sj.sj_parser_new(options.max_capacity, options.max_depth);
        const zero_copy = if (self.parser) |p| p.zero_copy else options.zero_copy;

        if (!has_user_provided_parser) {
            self.cached_parser = parser;
        }

        // Ideally we'd like to return a richer error set here but we're limited by the minimal
        // error set of all the places tape() is called, since we want to do this parsing on demand.
        err.check(sj.sj_parser_parse(parser, self.s.ptr, self.s.len, zero_copy)) catch |e| {
            switch (e) {
                err.Error.TapeError, err.Error.UnclosedString, err.Error.Empty, err.Error.NAtomError, err.Error.TAtomError, err.Error.FAtomError => return std.json.Scanner.Error.UnexpectedEndOfInput,
                err.Error.Utf8Error, err.Error.NumberError, err.Error.UnescapedChars, err.Error.StringError, err.Error.DepthError, err.Error.Capacity => return std.json.Scanner.Error.SyntaxError,
                // The above were explicitly hit and mapped to the closest error that std.json uses. Below were never hit and are caught for safety.
                else => return std.json.Scanner.Error.SyntaxError,
            }
        };
        const c_tape = sj.sj_parser_get_tape_view(parser);
        const t = Tape.init(c_tape);
        self.cached_tape = t;

        return t;
    }

    const Tape = struct {
        tape: []const u64,
        string_buf: [*]const u8,

        fn init(c_tape: sj.sj_tape) Tape {
            return .{ .tape = c_tape.tape_ptr[0..c_tape.tape_len], .string_buf = c_tape.string_buf_ptr };
        }
    };

    const NextAllocStrategy = union(enum) {
        alloc_never,
        alloc_always: std.mem.Allocator,
        alloc_if_needed: std.mem.Allocator,
    };

    /// See [std.json.Scanner.peekNextTokenType()](https://ziglang.org/documentation/master/std/#std.json.Scanner.peekNextTokenType).
    pub fn peekNextTokenType(self: *TapeTokenSource) TapeTokenSource.PeekError!TokenType {
        const t = try self.tape();
        if (self.pos >= t.tape.len) {
            // Matching what next() returns.
            return TokenType.end_of_document;
        }

        const val = t.tape[self.pos];
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
            'l', 'u', 'd', 'Z' => return TokenType.number,
            else => unreachable,
        }
    }

    /// This function advances until the end of the object is found. For objects and arrays, this is until the
    /// closing delimiter. For numbers or strings, it's to the end of the number or string.
    pub fn skipValue(self: *TapeTokenSource) TapeTokenSource.SkipError!void {
        const t = try self.tape();
        if (self.pos >= t.tape.len) {
            return TapeTokenSource.SkipError.UnexpectedEndOfInput;
        }

        const val = t.tape[self.pos];
        self.pos += 1;

        switch (val >> 56) {
            'l', 'u', 'd' => self.pos += 1,
            '[', '{' => {
                const x = val & 0x0000_0000_ffff_ffff;
                self.pos = x;
            },
            else => {},
        }

        return {};
    }

    /// See [std.json.Token](https://ziglang.org/documentation/master/std/#std.json.Scanner.Token) for documentation of this function.
    pub fn next(self: *TapeTokenSource) TapeTokenSource.NextError!std.json.Token {
        return self.nextInternal(.alloc_never, null) catch |e| {
            switch (e) {
                TapeTokenSource.AllocError.ValueTooLong => unreachable,
                else => |other| return other,
            }
        };
    }

    /// See [std.json.Token](https://ziglang.org/documentation/master/std/#std.json.Scanner.Token) for documentation of `nextAlloc*()` function.
    pub fn nextAllocMax(self: *TapeTokenSource, allocator: std.mem.Allocator, when: std.json.AllocWhen, max_value_len: usize) TapeTokenSource.AllocError!Token {
        const nextAlloc: NextAllocStrategy = switch (when) {
            .alloc_if_needed => .{ .alloc_if_needed = allocator },
            .alloc_always => .{ .alloc_always = allocator },
        };
        return self.nextInternal(nextAlloc, max_value_len);
    }

    pub fn deinit(self: *TapeTokenSource) void {
        if (self.cached_parser) |parser| {
            sj.sj_parser_free(parser);
        }
    }

    fn nextInternal(self: *TapeTokenSource, when: NextAllocStrategy, max_value_len: ?usize) TapeTokenSource.AllocError!std.json.Token {
        const t = try self.tape();
        if (self.pos >= t.tape.len) {
            return Token.end_of_document;
        }
        const val = t.tape[self.pos];
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
                const index = 0x00FF_FFFF_FFFF_FFFF & val;
                const len = std.mem.readInt(u32, t.string_buf[index .. index + 4][0..4], .little);
                const s = t.string_buf[index + 4 .. index + 4 + len];

                switch (when) {
                    .alloc_always => |allocator| {
                        if (s.len > max_value_len orelse std.math.maxInt(usize)) {
                            return TapeTokenSource.AllocError.ValueTooLong;
                        } else {
                            return Token{ .allocated_string = try allocator.dupe(u8, s) };
                        }
                    },
                    .alloc_if_needed, .alloc_never => return Token{ .string = s },
                }
            },
            'Z' => {
                const index = 0x00FF_FFFF_FFFF_FFFF & val;
                const len = std.mem.readInt(u32, t.string_buf[index .. index + 4][0..4], .little);
                const s = t.string_buf[index + 4 .. index + 4 + len];

                return switch (when) {
                    .alloc_always => |allocator| if (s.len > max_value_len orelse std.math.maxInt(usize))
                        TapeTokenSource.AllocError.ValueTooLong
                    else
                        Token{ .allocated_number = try allocator.dupe(u8, s) },
                    .alloc_if_needed, .alloc_never => return Token{ .number = s },
                };
            },
            'l' => {
                const num: i64 = @bitCast(t.tape[self.pos]);
                const num_str = std.mem.print(&self.scratch, "{d}", .{num}) catch unreachable;
                const result = switch (when) {
                    .alloc_always, .alloc_if_needed => |allocator| if (num_str.len > max_value_len orelse std.math.maxInt(usize))
                        TapeTokenSource.AllocError.ValueTooLong
                    else
                        Token{ .allocated_number = try allocator.dupe(u8, num_str) },
                    .alloc_never => Token{ .number = num_str },
                };
                self.pos += 1;
                return result;
            },
            'u' => {
                const num: u64 = @bitCast(t.tape[self.pos]);
                const num_str = std.mem.print(&self.scratch, "{d}", .{num}) catch unreachable;
                const result = switch (when) {
                    .alloc_always, .alloc_if_needed => |allocator| if (num_str.len > max_value_len orelse std.math.maxInt(usize))
                        TapeTokenSource.AllocError.ValueTooLong
                    else
                        Token{ .allocated_number = try allocator.dupe(u8, num_str) },
                    .alloc_never => Token{ .number = num_str },
                };
                self.pos += 1;
                return result;
            },
            'd' => {
                const num: f64 = @bitCast(t.tape[self.pos]);
                const num_str = std.mem.print(&self.scratch, "{e}", .{num}) catch unreachable;
                const result = switch (when) {
                    .alloc_always, .alloc_if_needed => |allocator| if (num_str.len > max_value_len orelse std.math.maxInt(usize))
                        TapeTokenSource.AllocError.ValueTooLong
                    else
                        Token{ .allocated_number = try allocator.dupe(u8, num_str) },
                    .alloc_never => Token{ .number = num_str },
                };
                self.pos += 1;
                return result;
            },
            else => unreachable,
        }
        unreachable;
    }
};

test TapeTokenSource {
    var scanner = TapeTokenSource.init("{\"foo\": [123.0, 456, -154]}\n");
    defer scanner.deinit();
    try std.testing.expectEqual(Token.object_begin, try scanner.next());
    try std.testing.expectEqualSlices(u8, "foo", (try scanner.next()).string);
    try std.testing.expectEqual(Token.array_begin, try scanner.next());
    try std.testing.expectEqualSlices(u8, "1.23e2", (try scanner.next()).number);
    try std.testing.expectEqualSlices(u8, "456", (try scanner.next()).number);
    try std.testing.expectEqualSlices(u8, "-154", (try scanner.next()).number);
    try std.testing.expectEqual(Token.array_end, try scanner.next());
    try std.testing.expectEqual(Token.object_end, try scanner.next());
    try std.testing.expectEqual(Token.end_of_document, try scanner.next());
}

test "zero copy" {
    const fixtures = @import("fixtures.zig");
    const parser = TapeParser.init(.{ .zero_copy = true });
    defer parser.deinit();
    var source = TapeTokenSource.initWithParser(fixtures.export_data, parser);
    defer source.deinit();
    var c_parser = TapeParser.init(.{ .zero_copy = false });
    defer c_parser.deinit();
    var c_source = TapeTokenSource.initWithParser(fixtures.export_data, c_parser);
    defer c_source.deinit();
    const result = try std.json.parseFromTokenSource(fixtures.Export, std.testing.allocator, &source, .{});
    defer result.deinit();
    const c_result = try std.json.parseFromTokenSource(fixtures.Export, std.testing.allocator, &c_source, .{});
    defer c_result.deinit();

    try std.testing.expectEqualDeep(c_result, result);
}

test "max_alloc_len string" {
    var scanner = TapeTokenSource.init("\"abcdefg\"");
    defer scanner.deinit();

    // No alloc because we only do it if needed.
    var s = (try scanner.nextAllocMax(std.testing.allocator, .alloc_if_needed, 3)).string;
    try std.testing.expectEqualSlices(u8, "abcdefg", s);
    scanner.reset();

    // No error because we have just enough space.
    s = (try scanner.nextAllocMax(std.testing.allocator, .alloc_always, 7)).allocated_string;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualSlices(u8, "abcdefg", s);
    scanner.reset();

    try std.testing.expectError(std.json.Scanner.AllocError.ValueTooLong, scanner.nextAllocMax(std.testing.allocator, .alloc_always, 6));
}

test "max_alloc_len big int" {
    var scanner = TapeTokenSource.init("99999999999999999999");
    defer scanner.deinit();

    // No alloc because we only do it if needed.
    var s = (try scanner.nextAllocMax(std.testing.allocator, .alloc_if_needed, 3)).number;
    try std.testing.expectEqualSlices(u8, "99999999999999999999", s);
    scanner.reset();

    // No error because we have just enough space.
    s = (try scanner.nextAllocMax(std.testing.allocator, .alloc_always, 20)).allocated_number;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualSlices(u8, "99999999999999999999", s);
    scanner.reset();

    try std.testing.expectError(std.json.Scanner.AllocError.ValueTooLong, scanner.nextAllocMax(std.testing.allocator, .alloc_always, 19));
}

test "max_alloc_len u64" {
    var scanner = TapeTokenSource.init("12345");
    defer scanner.deinit();

    // Numbers eagerly allocated
    try std.testing.expectError(std.json.Scanner.AllocError.ValueTooLong, scanner.nextAllocMax(std.testing.allocator, .alloc_if_needed, 3));
    scanner.reset();

    // No error because we have just enough space.
    const s = (try scanner.nextAllocMax(std.testing.allocator, .alloc_always, 5)).allocated_number;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualSlices(u8, "12345", s);
    scanner.reset();

    try std.testing.expectError(std.json.Scanner.AllocError.ValueTooLong, scanner.nextAllocMax(std.testing.allocator, .alloc_always, 4));
}

test "max_alloc_len i64" {
    var scanner = TapeTokenSource.init("-1234");
    defer scanner.deinit();

    // Numbers eagerly allocated
    try std.testing.expectError(std.json.Scanner.AllocError.ValueTooLong, scanner.nextAllocMax(std.testing.allocator, .alloc_if_needed, 3));
    scanner.reset();

    // No error because we have just enough space.
    const s = (try scanner.nextAllocMax(std.testing.allocator, .alloc_always, 5)).allocated_number;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualSlices(u8, "-1234", s);
    scanner.reset();

    try std.testing.expectError(std.json.Scanner.AllocError.ValueTooLong, scanner.nextAllocMax(std.testing.allocator, .alloc_always, 4));
}

test "max_alloc_len f64" {
    var scanner = TapeTokenSource.init("1.234");
    defer scanner.deinit();

    // Numbers eagerly allocated
    try std.testing.expectError(std.json.Scanner.AllocError.ValueTooLong, scanner.nextAllocMax(std.testing.allocator, .alloc_if_needed, 3));
    scanner.reset();

    // No error because we have just enough space.
    const s = (try scanner.nextAllocMax(std.testing.allocator, .alloc_always, 7)).allocated_number;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualSlices(u8, "1.234e0", s);
    scanner.reset();

    try std.testing.expectError(std.json.Scanner.AllocError.ValueTooLong, scanner.nextAllocMax(std.testing.allocator, .alloc_always, 4));
}

test "inner parse" {
    var scanner = TapeTokenSource.init("1234");
    defer scanner.deinit();
    const r = try (std.json.innerParse(u32, std.testing.allocator, &scanner, .{ .allocate = .alloc_always, .max_value_len = 15 }));
    try std.testing.expectEqual(1234, r);
}

test "token source lazily parses" {
    var scanner = TapeTokenSource.init("1234");
    defer scanner.deinit();
    try std.testing.expectEqual(null, scanner.cached_parser);
    try std.testing.expectEqual(null, scanner.cached_tape);

    _ = try scanner.next();
    try std.testing.expect(scanner.cached_parser != null);
    try std.testing.expect(scanner.cached_tape != null);
}

test "user-provided parser" {
    const docs = [_][]const u8{
        "{\"dinner\": \"food\"}",
        "{\"dinner\": \"lasagna\"}",
        "{\"dinner\": \"chips\"}",
    };

    const parser = TapeParser.init(.{});
    defer parser.deinit();

    const S = struct { dinner: []const u8 };
    var results: std.ArrayList(std.json.Parsed(S)) = try .initCapacity(std.testing.allocator, docs.len);
    defer results.deinit(std.testing.allocator);

    for (docs) |doc| {
        var source = TapeTokenSource.initWithParser(doc, parser);
        defer source.deinit();
        const result = try std.json.parseFromTokenSource(S, std.testing.allocator, &source, .{});
        try results.append(std.testing.allocator, result);
    }

    const expected = [_][]const u8{
        "food",
        "lasagna",
        "chips",
    };

    for (expected, results.items) |expectation, result| {
        try std.testing.expectEqualStrings(expectation, result.value.dinner);
        result.deinit();
    }
}

test "max depth" {
    const fixtures = @import("fixtures.zig");

    const parser = TapeParser.init(.{ .max_depth = 1 });
    defer parser.deinit();

    var tokenSource = TapeTokenSource.initWithParser(fixtures.export_data, parser);
    defer tokenSource.deinit();

    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, std.json.parseFromTokenSource(fixtures.Export, std.testing.allocator, &tokenSource, .{}));
}

test "max capacity" {
    const fixtures = @import("fixtures.zig");

    const parser = TapeParser.init(.{ .max_capacity = 100 });
    defer parser.deinit();

    var tokenSource = TapeTokenSource.initWithParser(fixtures.export_data, parser);
    defer tokenSource.deinit();

    try std.testing.expectError(std.json.Scanner.Error.SyntaxError, std.json.parseFromTokenSource(fixtures.Export, std.testing.allocator, &tokenSource, .{}));
}
