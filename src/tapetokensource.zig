const std = @import("std");
const sj = @import("simdjson");
const err = @import("error.zig");

const Token = std.json.Token;
const TokenType = std.json.TokenType;

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

    // Built once on demand, cached for future use until deinit.
    cached_tape: ?Tape = null,
    cached_parser: ?*sj.sj_parser = null,

    pub const NextError = std.json.Scanner.NextError;
    pub const PeekError = std.json.Scanner.PeekError;
    pub const SkipError = std.json.Scanner.SkipError;
    pub const AllocError = std.json.Scanner.AllocError;

    pub fn init(s: []const u8) TapeTokenSource {
        return .{ .s = s };
    }

    fn tape(self: *TapeTokenSource) std.json.Scanner.Error!Tape {
        return self.cached_tape orelse self.parse_and_cache_tape();
    }

    fn parse_and_cache_tape(self: *TapeTokenSource) std.json.Scanner.Error!Tape {
        const parser = sj.sj_parser_new();
        self.cached_parser = parser;

        // Ideally we'd like to return a richer error set here but we're limited by the minimal
        // error set of all the places tape() is called, since we want to do this parsing on demand.
        err.check(sj.sj_parser_parse(parser, self.s.ptr, self.s.len)) catch |e| {
            switch (e) {
                err.Error.TapeError, err.Error.UnclosedString, err.Error.Empty, err.Error.NAtomError, err.Error.TAtomError, err.Error.FAtomError => return std.json.Scanner.Error.UnexpectedEndOfInput,
                err.Error.Utf8Error, err.Error.NumberError, err.Error.UnescapedChars, err.Error.StringError, err.Error.DepthError => return std.json.Scanner.Error.SyntaxError,
                else => unreachable,
            }
        };
        const c_tape = sj.sj_parser_get_tape_view(parser);
        const t = Tape.init(c_tape);
        self.cached_tape = t;

        return t;
    }

    const Tape = struct {
        tape: []u64,
        string_buf: [*]u8,

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
        return self.next_internal(.alloc_never);
    }

    /// See [std.json.Token](https://ziglang.org/documentation/master/std/#std.json.Scanner.Token) for documentation of `nextAlloc*()` function.
    pub fn nextAllocMax(self: *TapeTokenSource, allocator: std.mem.Allocator, when: std.json.AllocWhen, max_value_len: usize) !Token {
        _ = max_value_len;
        const nextAlloc: NextAllocStrategy = switch (when) {
            .alloc_if_needed => .{ .alloc_if_needed = allocator },
            .alloc_always => .{ .alloc_always = allocator },
        };
        return self.next_internal(nextAlloc);
    }

    pub fn deinit(self: *TapeTokenSource) void {
        if (self.cached_parser) |parser| {
            sj.sj_parser_free(parser);
        }
    }

    fn next_internal(
        self: *TapeTokenSource,
        when: NextAllocStrategy,
    ) TapeTokenSource.NextError!std.json.Token {
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

                return switch (when) {
                    .alloc_always => |allocator| Token{ .allocated_string = try allocator.dupe(u8, s) },
                    .alloc_if_needed, .alloc_never => Token{ .string = s },
                };
            },
            'Z' => {
                const index = 0x00FF_FFFF_FFFF_FFFF & val;
                const len = std.mem.readInt(u32, t.string_buf[index .. index + 4][0..4], .little);
                const s = t.string_buf[index + 4 .. index + 4 + len];

                return switch (when) {
                    .alloc_always => |allocator| Token{ .allocated_number = try allocator.dupe(u8, s) },
                    .alloc_if_needed, .alloc_never => Token{ .number = s },
                };
            },
            'l' => {
                const num: i64 = @bitCast(t.tape[self.pos]);
                const num_str = std.mem.print(&self.scratch, "{d}", .{num}) catch unreachable;
                const result = switch (when) {
                    .alloc_always, .alloc_if_needed => |allocator| Token{ .allocated_number = try allocator.dupe(u8, num_str) },
                    .alloc_never => Token{ .number = num_str },
                };
                self.pos += 1;
                return result;
            },
            'u' => {
                const num: u64 = @bitCast(t.tape[self.pos]);
                const num_str = std.mem.print(&self.scratch, "{d}", .{num}) catch unreachable;
                const result = switch (when) {
                    .alloc_always, .alloc_if_needed => |allocator| Token{ .allocated_number = try allocator.dupe(u8, num_str) },
                    .alloc_never => Token{ .number = num_str },
                };
                self.pos += 1;
                return result;
            },
            'd' => {
                const num: f64 = @bitCast(t.tape[self.pos]);
                const num_str = std.mem.print(&self.scratch, "{e}", .{num}) catch unreachable;
                const result = switch (when) {
                    .alloc_always, .alloc_if_needed => |allocator| Token{ .allocated_number = try allocator.dupe(u8, num_str) },
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
