const std = @import("std");
const sj = @import("simdjson");
const err = @import("error.zig");

pub const minify = @import("minify.zig").minify;
pub const validate_utf8 = @import("validateUTF8.zig").validate_utf8;

const Token = std.json.Token;
const TokenType = std.json.TokenType;

// https://github.com/simdjson/simdjson/blob/master/doc/tape.md
pub const TapeTokenSource = struct {
    tape: Tape,
    pos: usize = 1, // Skip the first r entry.
    gpa: std.mem.Allocator,

    pub const NextError = std.json.Scanner.NextError;
    pub const PeekError = std.json.Scanner.PeekError;
    pub const SkipError = std.json.Scanner.SkipError;
    pub const AllocError = std.json.Scanner.AllocError;

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
            'l', 'u', 'd', 'Z' => return TokenType.number,
            else => unreachable,
        }
    }

    pub fn skipValue(self: *TapeTokenSource) TapeTokenSource.SkipError!void {
        const val = self.tape.tape[self.pos];
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

    pub fn next(self: *TapeTokenSource) TapeTokenSource.NextError!std.json.Token {
        return self.next_internal(self.gpa, .alloc_if_needed);
    }

    /// https://ziglang.org/documentation/master/std/#std.json.Scanner.Token
    pub fn nextAllocMax(self: *TapeTokenSource, allocator: std.mem.Allocator, when: std.json.AllocWhen, max_value_len: usize) !Token {
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
                const index = 0x00FF_FFFF_FFFF_FFFF & val;
                const len = std.mem.readInt(u32, self.tape.string_buf[index .. index + 4][0..4], .little);
                const s = self.tape.string_buf[index + 4 .. index + 4 + len];

                switch (when) {
                    .alloc_always => return Token{ .allocated_string = try allocator.dupe(u8, s) },
                    .alloc_if_needed => return Token{ .string = s },
                }
            },
            'Z' => {
                const index = 0x00FF_FFFF_FFFF_FFFF & val;
                const len = std.mem.readInt(u32, self.tape.string_buf[index .. index + 4][0..4], .little);
                const s = self.tape.string_buf[index + 4 .. index + 4 + len];

                switch (when) {
                    .alloc_always => return Token{ .allocated_number = try allocator.dupe(u8, s) },
                    .alloc_if_needed => return Token{ .number = s },
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
            else => unreachable,
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
) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    const parser = sj.sj_parser_new();
    defer sj.sj_parser_free(parser);

    err.check(sj.sj_parser_parse(parser, s.ptr, s.len)) catch |e| {
        switch (e) {
            err.Error.TapeError, err.Error.UnclosedString, err.Error.Empty => return std.json.Scanner.Error.UnexpectedEndOfInput,
            err.Error.Utf8Error => return std.json.Scanner.Error.SyntaxError,
            err.Error.DepthError => return std.json.ParseFromValueError.UnexpectedToken,
            err.Error.UnescapedChars => return std.json.Scanner.Error.SyntaxError,
            else => unreachable,
        }
    };
    const c_tape = sj.sj_parser_get_tape_view(parser);
    const tape = Tape.init(c_tape);

    var tapeTokenSource = TapeTokenSource{ .tape = tape, .gpa = allocator };
    defer tapeTokenSource.deinit();

    // For now, don't allow .allocate_if_needed in the options, as it makes us return a slice to the parser just
    // freed above.
    var o = options;
    o.allocate = null;

    return std.json.parseFromTokenSource(
        T,
        allocator,
        &tapeTokenSource,
        o,
    );
}

const Tape = struct {
    tape: []u64,
    string_buf: [*]u8,

    fn init(c_tape: sj.sj_tape) Tape {
        return .{ .tape = c_tape.tape_ptr[0..c_tape.tape_len], .string_buf = c_tape.string_buf_ptr };
    }
};

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
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, result);

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
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, parseFromSlice(u32, std.testing.allocator, "", .{}));
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, std.json.parseFromSlice(u32, std.testing.allocator, "", .{}));
}

test "malformed: truncated array" {
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, parseFromSlice([]u32, std.testing.allocator, "[1,", .{}));
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, std.json.parseFromSlice([]u32, std.testing.allocator, "[1,", .{}));
}

test "malformed: unclosed string" {
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, parseFromSlice([]const u8, std.testing.allocator, "\"abc", .{}));
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

test "malformed: balanced nesting beyond depth limit" {
    const depth = 2000;
    const buf = try std.testing.allocator.alloc(u8, depth * 2);
    defer std.testing.allocator.free(buf);
    @memset(buf[0..depth], '[');
    @memset(buf[depth..], ']');
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, parseFromSlice(u32, std.testing.allocator, buf, .{}));
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, std.json.parseFromSlice(u32, std.testing.allocator, buf, .{}));
}

test "malformed: unbalanced nesting beyond depth limit" {
    const depth = 2000;
    const buf = try std.testing.allocator.alloc(u8, depth);
    defer std.testing.allocator.free(buf);
    @memset(buf, '[');
    try std.testing.expectError(std.json.Scanner.Error.UnexpectedEndOfInput, parseFromSlice(u32, std.testing.allocator, buf, .{}));
    try std.testing.expectError(std.json.ParseFromValueError.UnexpectedToken, std.json.parseFromSlice(u32, std.testing.allocator, buf, .{}));
}

test "malformed: integer beyond u64 range" {
    const val = try parseFromSlice(u128, std.testing.allocator, "99999999999999999999", .{});
    defer val.deinit();
    try std.testing.expectEqual(99999999999999999999, val.value);
    const val2 = try std.json.parseFromSlice(u128, std.testing.allocator, "99999999999999999999", .{});
    defer val2.deinit();
    try std.testing.expectEqual(99999999999999999999, val2.value);
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

test "fuzz parseFromSlice" {
    const t = struct {
        var data: [1_000]u8 = undefined;
        fn fuzz_parseFromSlice(_: void, smith: *std.testing.Smith) !void {
            const len = smith.slice(&data);
            _ = parseFromSlice(u8, std.testing.allocator, data[0..len], .{}) catch {};
            _ = parseFromSlice(bool, std.testing.allocator, data[0..len], .{}) catch {};
            _ = parseFromSlice([]u8, std.testing.allocator, data[0..len], .{}) catch {};
            _ = parseFromSlice([][]u8, std.testing.allocator, data[0..len], .{}) catch {};

            const S = struct {
                @"test": [15]T,
                const T = struct {
                    f1: F,
                    f2: F,
                    const F = struct { size: ?i16 };
                };
            };
            _ = parseFromSlice(S, std.testing.allocator, data[0..len], .{}) catch {};

            _ = parseFromSlice(union(enum) { a: u32, f: f64, l: bool }, std.testing.allocator, data[0..len], .{}) catch {};
        }
    };
    try std.testing.fuzz({}, t.fuzz_parseFromSlice, .{});
}

test "another large one" {
    const Export = struct {
        metadata: Metadata,
        users: []User,

        const Metadata = struct {
            configuration: Configuration,
            generated_at: []const u8, // ISO 8601 with offset
            generator: []const u8,
            schema_version: u32,
            statistics: Statistics,
            version: []const u8,
        };

        const Configuration = struct {
            checksum_algo: []const u8,
            compression: ?[]const u8,
            encryption: bool,
            export_settings: ExportSettings,
            include_nulls: bool,
            locale: []const u8,
            pretty_print: bool,
            source_systems: [][]const u8,
        };

        const ExportSettings = struct {
            batch_size: u32,
            retry_attempts: u32,
            timeout_seconds: u32,
        };

        const Statistics = struct {
            processing_time: ?f64, // null in the sample; adjust if it's really something else
            total_records: u64,
            validation_score: f64,
        };

        const User = struct {
            address: Address,
            age: u32,
            avatar_url: []const u8,
            balance: f64,
            bio: []const u8,
            birth_date: []const u8, // "YYYY-MM-DD"
            created_at: []const u8,
            currency: []const u8,
            deleted_at: ?[]const u8,
            email: []const u8,
            first_name: []const u8,
            gender: []const u8,
            id: []const u8, // UUID
            last_name: []const u8,
            metadata: UserMetadata,
            phone: []const u8, // string in the sample; keep as text to preserve leading zeros
            preferences: Preferences,
            premium: bool,
            scores: Scores,
            tags: [][]const u8,
            updated_at: ?[]const u8,
            username: []const u8,
            verified: bool,
        };

        const Address = struct {
            city: []const u8,
            coordinates: Coordinates,
            country: []const u8,
            postal_code: []const u8,
            state: []const u8,
            street: []const u8,
        };

        const Coordinates = struct {
            latitude: f64,
            longitude: f64,
        };

        const UserMetadata = struct {
            failed_attempts: u32,
            features_enabled: [][]const u8,
            last_login: ?[]const u8,
            login_count: u32,
            referral_code: []const u8,
            referred_by: ?[]const u8,
            subscription_tier: []const u8,
        };

        const Preferences = struct {
            language: []const u8,
            notifications: Notifications,
            privacy: Privacy,
            theme: []const u8,
            timezone: []const u8,
        };

        const Notifications = struct {
            email: bool,
            in_app: bool,
            push: bool,
            sms: bool,
        };

        const Privacy = struct {
            allow_indexing: bool,
            profile_visible: bool,
            show_email: bool,
            show_phone: bool,
        };

        const Scores = struct {
            activity: f64,
            engagement: f64,
            reliability: f64,
            trust: f64,
        };
    };

    const src =
        \\{
        \\"metadata": {
        \\"configuration": {
        \\"checksum_algo": "sha256",
        \\"compression": null,
        \\"encryption": false,
        \\"export_settings": {
        \\"batch_size": 1000,
        \\"retry_attempts": 3,
        \\"timeout_seconds": 300
        \\},
        \\"include_nulls": true,
        \\"locale": "tw",
        \\"pretty_print": true,
        \\"source_systems": [
        \\"crm",
        \\"erp",
        \\"analytics",
        \\"warehouse"
        \\]
        \\},
        \\"generated_at": "2026-01-23T16:50:19+01:00",
        \\"generator": "jsongen",
        \\"schema_version": 5,
        \\"statistics": {
        \\"processing_time": null,
        \\"total_records": 0,
        \\"validation_score": 0.98
        \\},
        \\"version": "2.1.0"
        \\},
        \\"users": [
        \\{"address":{"city":"Corpus Christi","coordinates":{"latitude":-4.940006,"longitude":-92.766162},"country":"Turkmenistan","postal_code":"15178","state":"Connecticut","street":"5307 Lake Streetberg"},"age":74,"avatar_url":"https://picsum.photos/200/200","balance":5732.81,"bio":"Mine positively Rican lemony both who yesterday we respect point. Where nap is up to hungrily gain whole secondly does. Without himself whom still exaltation since example here several lastly. Out goodness shark those crowded shopping sit myself there they. Despite dynasty pod single frankly early then for mustering hmm. Group rarely balloon those alternatively how which mine backwards hundred. Itself that plenty clarity both she he wad mysterious our. Fantastic exaltation might her could eek French since rarely us.","birth_date":"1952-11-10","created_at":"2022-12-11T14:48:29Z","currency":"KYD","deleted_at":null,"email":"ressieraynor@jacobson.com","first_name":"Aylin","gender":"female","id":"9c8ad4d4-8039-4dc3-9deb-05d7277b23cc","last_name":"Schuster","metadata":{"failed_attempts":1,"features_enabled":["zero administration","context-sensitive","Total"],"last_login":null,"login_count":567,"referral_code":"KPNPfhXT","referred_by":"911c02c3-64a5-40fc-bc6e-2cd3199d3977","subscription_tier":"free"},"phone":"3578367644","preferences":{"language":"sg","notifications":{"email":false,"in_app":false,"push":true,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"light","timezone":"Middle East Standard Time"},"premium":false,"scores":{"activity":90.82036947237935,"engagement":12.549412970982187,"reliability":24.995091175451435,"trust":83.52216779109818},"tags":["Face to face","fault-tolerant","open system"],"updated_at":null,"username":"Volkman1654","verified":false},
        \\{"address":{"city":"Omaha","coordinates":{"latitude":-4.768494,"longitude":-47.684056},"country":"Croatia","postal_code":"83186","state":"Florida","street":"8728 North Portton"},"age":64,"avatar_url":"https://picsum.photos/200/200","balance":9847.91,"bio":"Who those we for all anthology company than his fortnightly. Life cook might unless Kyrgyz another one that how here. Waiter collection depending which house fortnightly that next jumper alternatively. Another our soon myself who tomorrow pounce of was is. All both then as throughout shark on as each afterwards. Numerous group later him pack those has everything hers egg. Finally archipelago as anyone may by wisp problem orange ouch. Her laugh up him huh nobody troop lazily ride I.","birth_date":"1962-04-18","created_at":"2025-06-14T01:30:22Z","currency":"VEF","deleted_at":null,"email":"thadcollier@cremin.org","first_name":"Connie","gender":"female","id":"520f9766-3b68-4eba-952b-7408a41e2fdc","last_name":"Dietrich","metadata":{"failed_attempts":3,"features_enabled":["Managed","hybrid","optimizing"],"last_login":"1988-08-25T14:19:31Z","login_count":492,"referral_code":"xMskfxgQ","referred_by":"0f34ca21-3bf5-4720-86b8-4dea20e3e1ae","subscription_tier":"enterprise"},"phone":"2753852811","preferences":{"language":"gn","notifications":{"email":true,"in_app":false,"push":true,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"light","timezone":"Dateline Standard Time"},"premium":true,"scores":{"activity":64.69503997754394,"engagement":56.72263027236675,"reliability":29.54711633711981,"trust":84.71160261137818},"tags":["tertiary","optimizing","success","projection","info-mediaries","reciprocal"],"updated_at":"1900-12-31T16:28:56Z","username":"Bailey9562","verified":false},
        \\{"address":{"city":"New Orleans","coordinates":{"latitude":-40.474085,"longitude":-39.089549},"country":"France","postal_code":"35814","state":"Alabama","street":"81071 New Missionport"},"age":31,"avatar_url":"https://picsum.photos/200/200","balance":4850.45,"bio":"Whom some horde onto myself without jump I herself cruelly. Infrequently yours movement calm any dance yay infrequently Bahamian there. Eventually grow secondly this verb under them oops cruelly in. Had government always result including everybody in say was comb. However why monthly most to should many to onto next. Gleaming much tonight than indeed your the mob owing your. Eek theirs really point it lucky whose when coat as. Metal set moreover tomorrow anger it so must enthusiastically shy.","birth_date":"1995-08-24","created_at":"2021-09-23T10:19:56Z","currency":"CNY","deleted_at":null,"email":"autumnquitzon@jewess.biz","first_name":"Terrell","gender":"female","id":"36f1d38d-6d14-4ce1-a84f-a9267fda878b","last_name":"Klocko","metadata":{"failed_attempts":2,"features_enabled":["Re-contextualized","non-volatile","frame"],"last_login":"2006-04-10T02:53:13Z","login_count":421,"referral_code":"hgStNQFB","referred_by":null,"subscription_tier":"pro"},"phone":"2266307694","preferences":{"language":"ff","notifications":{"email":false,"in_app":false,"push":true,"sms":false},"privacy":{"allow_indexing":false,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"light","timezone":"Fiji Standard Time"},"premium":false,"scores":{"activity":10.885160726910051,"engagement":18.31147798456419,"reliability":31.15933433180487,"trust":1.9354971526889542},"tags":["Sharable","encryption"],"updated_at":"2021-05-24T12:48:56Z","username":"Jenkins7095","verified":false},
        \\{"address":{"city":"Detroit","coordinates":{"latitude":40.947722,"longitude":-168.391616},"country":"United Arab Emirates","postal_code":"42979","state":"Illinois","street":"150 Neckborough"},"age":62,"avatar_url":"https://picsum.photos/200/200","balance":3104.2,"bio":"From can thing still fondly hand alone month huh on. Apro a mob then supermarket were several bouquet up for. Metal where year so Polynesian Aristotelian yikes any their she. Whose finally forget someone man to wisdom example Slovak off. Mob himself before spin will next throughout since Turkish hers. Cloud wall Intelligent secondly myself there at those deeply pounce. Impress constantly most ingeniously whom is those from never how. Highly whose yours uncle whole nightly cry each exaltation whose.","birth_date":"1964-02-18","created_at":"2020-09-11T04:00:22Z","currency":"BHD","deleted_at":null,"email":"eddiefunk@powlowski.biz","first_name":"Wanda","gender":"male","id":"1fb2c2ea-7296-48a8-82e3-779528d24cef","last_name":"Swaniawski","metadata":{"failed_attempts":5,"features_enabled":["hardware","Cross-group","task-force"],"last_login":"1998-01-09T13:37:31Z","login_count":628,"referral_code":"BwVokLLC","referred_by":null,"subscription_tier":"enterprise"},"phone":"7815783533","preferences":{"language":"af","notifications":{"email":true,"in_app":true,"push":true,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":true,"show_email":false,"show_phone":false},"theme":"dark","timezone":"UTC-11"},"premium":true,"scores":{"activity":16.57560728806395,"engagement":86.49084985068542,"reliability":78.73172504594346,"trust":78.23974666756973},"tags":["stable","foreground","protocol","grid-enabled","solution-oriented","conglomeration"],"updated_at":null,"username":"Watsica9367","verified":true},
        \\{"address":{"city":"Omaha","coordinates":{"latitude":21.997266,"longitude":-25.770471},"country":"Niue","postal_code":"25741","state":"Connecticut","street":"99081 New Islandbury"},"age":72,"avatar_url":"https://picsum.photos/200/200","balance":5954.38,"bio":"That insufficient door to weekly virtually under upstairs annually quarterly. Always knit problem shower content all quarterly go ours orchard. Ride eventually yourselves am something we my why blue all. All Parisian where today on this still yourself together once. Calm that shop whose in lastly somebody one them still. Fire over nevertheless heavy be ourselves this it advice last. Absolutely a several first have whom verb me recently under. Energetic we Icelandic hair wash Aristotelian too yesterday their perfectly.","birth_date":"1954-10-23","created_at":"2022-10-27T07:52:19Z","currency":"FJD","deleted_at":null,"email":"carlikulas@prohaska.name","first_name":"Magdalen","gender":"female","id":"53f0cde1-fd3a-416e-b207-653a88aac7f5","last_name":"Lowe","metadata":{"failed_attempts":2,"features_enabled":["Digitized","algorithm","responsive"],"last_login":"1980-01-22T18:23:21Z","login_count":784,"referral_code":"uQmJegIj","referred_by":"8fe82765-5127-41b1-94e2-610e24e1cd8a","subscription_tier":"basic"},"phone":"8789000739","preferences":{"language":"gu","notifications":{"email":true,"in_app":false,"push":false,"sms":true},"privacy":{"allow_indexing":true,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"dark","timezone":"Mid-Atlantic Standard Time"},"premium":false,"scores":{"activity":14.84791570607999,"engagement":40.68794773738663,"reliability":41.827779961388934,"trust":58.09122473221101},"tags":["mobile","Customer-focused","process improvement"],"updated_at":null,"username":"OReilly4321","verified":false},
        \\{"address":{"city":"Atlanta","coordinates":{"latitude":-60.424554,"longitude":-141.251259},"country":"Faroe Islands","postal_code":"11314","state":"Nebraska","street":"9026 Hillsmouth"},"age":70,"avatar_url":"https://picsum.photos/200/200","balance":6873.61,"bio":"Armchair upon they buy we host our alternatively cut often. Reel quickly throughout where carrot delay exaltation fortnightly of i.e.. Anyone who grapes therefore bale might there my line inside. Dress finally motivation wake soup out were finally his table. Importance enough rather set shall which infrequently through nightly under. Youth those everybody daily funny as you leap however within. At something before lots which off result oops ourselves furthermore. Formerly me infrequently i.e. light infrequently till it exist rain.","birth_date":"1956-11-18","created_at":"2025-06-13T21:50:38Z","currency":"KZT","deleted_at":null,"email":"gaetanoreynolds@west.org","first_name":"Darby","gender":"female","id":"79730a74-e393-437c-a31b-158596400be0","last_name":"Aufderhar","metadata":{"failed_attempts":2,"features_enabled":["coherent","directional","Cloned"],"last_login":"1931-02-18T21:24:53Z","login_count":682,"referral_code":"yQNgCykX","referred_by":"7bfe3b5c-8ed1-47f2-9ea6-53a637d49e0e","subscription_tier":"free"},"phone":"4746143047","preferences":{"language":"tw","notifications":{"email":true,"in_app":false,"push":true,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":true,"show_email":false,"show_phone":false},"theme":"dark","timezone":"Samara Time"},"premium":false,"scores":{"activity":17.314101902680473,"engagement":62.23790886004411,"reliability":27.12082169872632,"trust":79.00057565337448},"tags":["success","system-worthy","Multi-lateral","Public-key","human-resource","challenge","modular","Graphical User Interface"],"updated_at":"1941-01-16T20:29:39Z","username":"Renner6712","verified":true},
        \\{"address":{"city":"Fremont","coordinates":{"latitude":-19.211753,"longitude":79.14943},"country":"Guernsey","postal_code":"79693","state":"Alabama","street":"9021 New Squarestad"},"age":22,"avatar_url":"https://picsum.photos/200/200","balance":8261.43,"bio":"Quarterly within itself here ourselves several climb determination our weep. Him whoa by behind accordingly onto transportation yours moreover greatly. Whose a late tonight with never i.e. was phew sprint. Who out I my yesterday themselves hey still world choir. Sometimes Putinist part behind those all yet are our due. Me all on yearly however upon lots to hey win. With huge later quiver sigh about anyone few respect quickly. Virtually to where her up daily absolutely regularly in covey.","birth_date":"2004-08-04","created_at":"2020-08-22T01:44:03Z","currency":"NZD","deleted_at":null,"email":"adonislind@jerde.com","first_name":"Elwyn","gender":"male","id":"79e5b7f9-b4f6-4c16-961a-f31bbc17b537","last_name":"Mann","metadata":{"failed_attempts":4,"features_enabled":["Vision-oriented","Robust","application"],"last_login":null,"login_count":13,"referral_code":"DQTqTyUR","referred_by":"59af5679-1767-4905-95db-6538a777f503","subscription_tier":"enterprise"},"phone":"7442215169","preferences":{"language":"ga","notifications":{"email":false,"in_app":true,"push":true,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":true,"show_email":false,"show_phone":false},"theme":"dark","timezone":"Newfoundland Standard Time"},"premium":true,"scores":{"activity":16.87121222320295,"engagement":43.285442992996494,"reliability":60.79062826861447,"trust":15.295778635705345},"tags":["Multi-lateral","multi-tasking","Vision-oriented","Intuitive","mission-critical","multi-state"],"updated_at":"1942-02-28T03:08:54Z","username":"Connelly6610","verified":true},
        \\{"address":{"city":"Indianapolis","coordinates":{"latitude":-27.917285,"longitude":134.508235},"country":"Chile","postal_code":"30655","state":"Washington","street":"17252 East Laneside"},"age":41,"avatar_url":"https://picsum.photos/200/200","balance":2808.76,"bio":"Clump secondly of murder justly water fantastic huge occasionally fatally. Stay yearly Japanese another us in here this supermarket where. Yikes her all gifted example my after whom great wheat. Frail hers itself harm fact few yourself she everybody that. Hall many should here lately oops person us next what. Which yearly work why in nobody lastly without by some. Afghan eventually Senegalese themselves head yay themselves who should glamorous. Wrack bouquet should today videotape us harvest then you homework.","birth_date":"1985-12-18","created_at":"2021-07-03T19:13:16Z","currency":"TWD","deleted_at":null,"email":"andreanneschuppe@mcdermott.info","first_name":"Alden","gender":"female","id":"2af890d3-45b0-4e4e-ac04-68e88e636f90","last_name":"Watsica","metadata":{"failed_attempts":4,"features_enabled":["global","parallelism","migration"],"last_login":"1983-06-19T03:12:06Z","login_count":67,"referral_code":"KuzRzuhQ","referred_by":"0a9a88f8-8bd8-4e3f-ad46-8d8b4ba70cde","subscription_tier":"free"},"phone":"1548511260","preferences":{"language":"qu","notifications":{"email":false,"in_app":true,"push":true,"sms":false},"privacy":{"allow_indexing":false,"profile_visible":true,"show_email":false,"show_phone":false},"theme":"dark","timezone":"E. Europe Standard Time"},"premium":false,"scores":{"activity":3.950403395804277,"engagement":14.185383609603486,"reliability":58.56926054987556,"trust":1.6613660152011804},"tags":["Synchronised","leading edge","systematic","middleware","Cloned","24/7","matrix"],"updated_at":"1988-06-27T06:07:21Z","username":"Wolf4887","verified":true},
        \\{"address":{"city":"Charlotte","coordinates":{"latitude":72.183171,"longitude":165.282175},"country":"Italy","postal_code":"58215","state":"Virginia","street":"222 North Islandchester"},"age":55,"avatar_url":"https://picsum.photos/200/200","balance":7904.23,"bio":"Hastily most before every cheerful humour the Aristotelian besides so. Whom last dunk rudely leap this there ours garage soup. Hand what which whose company adventurous frequently respond all frequently. To indoors whose selfishly it generosity being truth full fade. Example has without everything this Elizabethan most yearly invention hundreds. To peep shake heavy hourly though give occasionally election yourselves. Furthermore repelling omen infrequently moreover here Portuguese may everybody relax. Whoever troop petrify anyone I anger tonight dream rarely great.","birth_date":"1971-03-27","created_at":"2022-12-11T08:08:43Z","currency":"XCD","deleted_at":null,"email":"wendellklein@heathcote.name","first_name":"Arlene","gender":"female","id":"bbef281d-4ef5-495f-b122-ce60a0d251df","last_name":"Gleason","metadata":{"failed_attempts":3,"features_enabled":["middleware","Intuitive","Assimilated"],"last_login":null,"login_count":960,"referral_code":"NqAlshOd","referred_by":null,"subscription_tier":"enterprise"},"phone":"6361637125","preferences":{"language":"fi","notifications":{"email":true,"in_app":false,"push":false,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"light","timezone":"SE Asia Standard Time"},"premium":true,"scores":{"activity":3.25106971201952,"engagement":46.30174487499714,"reliability":68.97648898059424,"trust":59.12306332469638},"tags":["Configurable","zero tolerance","Monitored","software","frame","Balanced","flexibility","Distributed"],"updated_at":"1915-03-30T09:52:05Z","username":"Metz9925","verified":false},
        \\{"address":{"city":"Atlanta","coordinates":{"latitude":-67.551762,"longitude":169.178304},"country":"Faroe Islands","postal_code":"88497","state":"Arizona","street":"1178 Wellsland"},"age":61,"avatar_url":"https://picsum.photos/200/200","balance":8047.32,"bio":"Blazer witty additionally of yesterday anything yikes certain this nest. Whomever it what Canadian everybody next elsewhere was mysteriously ourselves. Us adorable what who stemmed instead purely day along including. Divorce somebody snore it that occasionally include hundred this Hindu. For clump than account wipe play theirs team themselves group. Star that grains kuban moment had regularly goodness then hug. Anything from normally those may brace been monthly alternatively few. Might this oxygen his no now Polynesian onto below downstairs.","birth_date":"1965-03-24","created_at":"2022-07-31T06:22:17Z","currency":"LSL","deleted_at":null,"email":"elenorbahringer@kozey.net","first_name":"Ulices","gender":"male","id":"429d3267-abf3-4da3-8187-db38cf9097f9","last_name":"Leffler","metadata":{"failed_attempts":3,"features_enabled":["focus group","collaboration","Implemented"],"last_login":"1984-05-29T17:13:49Z","login_count":437,"referral_code":"TcBGgZMY","referred_by":null,"subscription_tier":"free"},"phone":"6096728328","preferences":{"language":"gv","notifications":{"email":true,"in_app":false,"push":false,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"auto","timezone":"SE Asia Standard Time"},"premium":false,"scores":{"activity":0.27709877828403495,"engagement":48.050798487491875,"reliability":18.991266057818812,"trust":70.99421258032663},"tags":["extranet","Vision-oriented","intermediate","Ergonomic","artificial intelligence"],"updated_at":"1969-10-06T07:37:33Z","username":"Kshlerin1173","verified":true},
        \\{"address":{"city":"Birmingham","coordinates":{"latitude":37.603329,"longitude":-64.735395},"country":"Wallis and Futuna","postal_code":"27192","state":"Louisiana","street":"136 East Alleytown"},"age":57,"avatar_url":"https://picsum.photos/200/200","balance":2024.61,"bio":"Harm scarcely this themselves upstairs somebody there ours some justice. Of such these world light for he they book Iranian. The aha besides house this these hourly him on another. Pound laugh candle tomorrow their yet she board what barely. Wave I quarterly sedge shall hers he whose shake shower. Is kill right Honduran ours in horde other this positively. Yikes party theirs is along whom then flock whatever snore. To turtle man owing as swan throw many sparse damage.","birth_date":"1969-06-11","created_at":"2020-11-27T02:41:56Z","currency":"BDT","deleted_at":null,"email":"darrellnienow@kerluke.name","first_name":"Ansel","gender":"male","id":"c2f53373-2e54-4a26-aa8a-089d2f6dafa2","last_name":"Considine","metadata":{"failed_attempts":2,"features_enabled":["bifurcated","6th generation","well-modulated"],"last_login":"1916-05-30T22:03:04Z","login_count":738,"referral_code":"jIReAoxK","referred_by":"facc9981-a473-4def-9661-707376f0e0b3","subscription_tier":"enterprise"},"phone":"1619847169","preferences":{"language":"ee","notifications":{"email":false,"in_app":false,"push":false,"sms":true},"privacy":{"allow_indexing":true,"profile_visible":true,"show_email":false,"show_phone":false},"theme":"dark","timezone":"Japan Standard Time"},"premium":false,"scores":{"activity":84.05409835386044,"engagement":20.940905672692402,"reliability":43.18791421256199,"trust":99.29680634445106},"tags":["Fundamental","Future-proofed","complexity","Proactive","policy","groupware","tangible","success"],"updated_at":"1965-04-26T05:56:47Z","username":"Ortiz7721","verified":true},
        \\{"address":{"city":"Anaheim","coordinates":{"latitude":-83.21064,"longitude":73.945161},"country":"Portugal","postal_code":"66234","state":"Maine","street":"984 Port Isleberg"},"age":26,"avatar_url":"https://picsum.photos/200/200","balance":676.79,"bio":"Consequently too sometimes we management whose last widen monthly due. Did was as we being stemmed yikes phew as read. That ours insufficient what my without besides intelligence do themselves. Here judge Iranian week still today which hers door whom. From quarterly where today whom that gently hers how afterwards. In she accordingly above even bevy which much tonight all. Posse happiness what murder mine should slide fleet shoes whatever. Everyone normally example been firstly pack her yesterday you despite.","birth_date":"2000-01-21","created_at":"2022-05-24T22:03:20Z","currency":"BWP","deleted_at":null,"email":"kobygleichner@schamberger.name","first_name":"Amya","gender":"female","id":"24d4dbd7-b07e-48ff-9310-d0749c5df6d8","last_name":"Hirthe","metadata":{"failed_attempts":1,"features_enabled":["uniform","Optimized","product"],"last_login":"2004-05-10T02:10:32Z","login_count":638,"referral_code":"xcqAuTBw","referred_by":"e1ffe8dc-ce42-483e-8ef8-731e6d5ef8d1","subscription_tier":"pro"},"phone":"1732145282","preferences":{"language":"bg","notifications":{"email":true,"in_app":true,"push":false,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":true,"show_email":false,"show_phone":false},"theme":"auto","timezone":"Singapore Standard Time"},"premium":false,"scores":{"activity":92.47395753369662,"engagement":49.56360283093195,"reliability":87.5076812924326,"trust":89.62625663475052},"tags":["framework","Self-enabling","matrices","intangible","Multi-channelled","object-oriented"],"updated_at":"1902-08-17T10:31:49Z","username":"Dibbert7274","verified":true},
        \\{"address":{"city":"St. Petersburg","coordinates":{"latitude":-40.861227,"longitude":121.235111},"country":"French Polynesia","postal_code":"21207","state":"South Dakota","street":"2953 Valleyston"},"age":37,"avatar_url":"https://picsum.photos/200/200","balance":2207.57,"bio":"Throughout Spanish of my his now of whose of ours. Consequence tonight himself hence for yet those so first everybody. Whatever aha regularly shake open it next credenza horde what. Yours jittery though as Colombian one accordingly badly in these. Barbadian Newtonian he is beneath from my obediently her an. Over Asian whoa to phew their daily something covey mob. My there from where driver throw till is yearly your. Their Sri-Lankan they patiently secondly man certain here Lebanese when.","birth_date":"1989-04-08","created_at":"2020-03-04T09:45:30Z","currency":"XPF","deleted_at":null,"email":"curtdietrich@shanahan.name","first_name":"Larry","gender":"male","id":"3be0c41d-7316-4396-a1bf-ed63dba1be3b","last_name":"Hyatt","metadata":{"failed_attempts":0,"features_enabled":["support","workforce","frame"],"last_login":null,"login_count":229,"referral_code":"KnKqqAFF","referred_by":null,"subscription_tier":"pro"},"phone":"6437145345","preferences":{"language":"km","notifications":{"email":true,"in_app":true,"push":true,"sms":true},"privacy":{"allow_indexing":true,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"auto","timezone":"Samara Time"},"premium":false,"scores":{"activity":26.420001490314675,"engagement":55.88419616988063,"reliability":13.347217557691145,"trust":9.710679738578262},"tags":["artificial intelligence","Multi-tiered","structure","executive","grid-enabled","Secured","Function-based","full-range"],"updated_at":"1910-05-07T15:39:23Z","username":"Jaskolski9480","verified":true},
        \\{"address":{"city":"Milwaukee","coordinates":{"latitude":-3.885036,"longitude":108.570916},"country":"Saint Helena, Ascension and Tristan da Cunha","postal_code":"34131","state":"Illinois","street":"2024 Lake Islandborough"},"age":50,"avatar_url":"https://picsum.photos/200/200","balance":150.71,"bio":"Ourselves outside would fortnightly kiss Monacan in below return time. Some therefore inside company ours of his anybody weekly it. Since we theirs us time occasion must be brain class. Whatever mine wealth where wisdom nearby hourly those me artist. Himself recently rather hall danger should pout elsewhere each star. Enough on Iranian of this early lately I wildlife been. Himself instance they somewhat choir whichever tomorrow smiling lately i.e.. Keyboard gee firstly summation other who may out they boldly.","birth_date":"1976-01-30","created_at":"2025-10-13T14:38:50Z","currency":"CAD","deleted_at":null,"email":"ashtynreichert@pouros.name","first_name":"Maverick","gender":"male","id":"6eece8d7-e836-4905-ba86-95d42fd07a83","last_name":"Friesen","metadata":{"failed_attempts":1,"features_enabled":["uniform","Multi-tiered","Fully-configurable"],"last_login":"1973-05-12T02:46:58Z","login_count":158,"referral_code":"RbKSKUaA","referred_by":"ca6be1bd-9a6c-4c61-a713-5f5453eb0951","subscription_tier":"enterprise"},"phone":"3516266035","preferences":{"language":"ii","notifications":{"email":true,"in_app":false,"push":false,"sms":false},"privacy":{"allow_indexing":false,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"auto","timezone":"Caucasus Standard Time"},"premium":true,"scores":{"activity":21.359281555079054,"engagement":95.38036727813969,"reliability":83.14005351311641,"trust":2.7268173263294786},"tags":["collaboration","Programmable"],"updated_at":null,"username":"Yost1026","verified":false},
        \\{"address":{"city":"Norfolk","coordinates":{"latitude":-79.902787,"longitude":117.421975},"country":"Myanmar","postal_code":"92681","state":"Utah","street":"711 West Centersborough"},"age":45,"avatar_url":"https://picsum.photos/200/200","balance":8848.24,"bio":"Everyone how myself themselves most first dig how our pride. Float agreeable previously laugh whom that instance yours whose loneliness. Shall genetics pain elsewhere elegantly tomorrow then humour mourn shall. In wrack had of from to us for aha those. Am tax somebody pleasure their his this he whose relent. Refill yesterday nothing today that above these eat twist huh. Your noisily that that case that who that to gracefully. Galaxy practically kindly them should pumpkin little everything thoughtfully Balinese.","birth_date":"1981-03-16","created_at":"2021-11-24T00:00:22Z","currency":"THB","deleted_at":null,"email":"shaynalakin@cummings.info","first_name":"Sandra","gender":"female","id":"6715f63e-4a34-443e-bf2b-15b55c8fe57e","last_name":"Bergnaum","metadata":{"failed_attempts":4,"features_enabled":["4th generation","Implemented","concept"],"last_login":null,"login_count":195,"referral_code":"BXViHnmb","referred_by":null,"subscription_tier":"pro"},"phone":"4680092031","preferences":{"language":"ny","notifications":{"email":true,"in_app":false,"push":true,"sms":false},"privacy":{"allow_indexing":true,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"auto","timezone":"Magadan Standard Time"},"premium":true,"scores":{"activity":93.25344747365605,"engagement":73.22158517454078,"reliability":8.419463538122072,"trust":96.08781634461927},"tags":["hierarchy","Expanded","bottom-line"],"updated_at":"1937-10-01T14:00:17Z","username":"Gottlieb2933","verified":true},
        \\{"address":{"city":"Cleveland","coordinates":{"latitude":21.10598,"longitude":61.595575},"country":"Saint Helena, Ascension and Tristan da Cunha","postal_code":"16647","state":"New Mexico","street":"115 Streamview"},"age":54,"avatar_url":"https://picsum.photos/200/200","balance":4319.52,"bio":"Strongly that what me because each line oops consequence one. His case anyone always later each upstairs then which forest. Brace embarrassed secondly should most off sleep backwards my turn. Because Elizabethan where can you previously nightly whatever his e.g.. Their be man bunch cancel has that an to drink. Chocolate next line exist whose frequently seldom load dive relent. This whose first us e.g. besides often this are is. All nightly fiction what this accordingly theater intensely did cooperative.","birth_date":"1972-03-11","created_at":"2024-12-19T11:47:26Z","currency":"IQD","deleted_at":null,"email":"jedidiahhintz@durgan.info","first_name":"Angel","gender":"female","id":"364aea27-c618-4153-bca6-7bccec5d40b2","last_name":"McDermott","metadata":{"failed_attempts":3,"features_enabled":["Total","global","solution-oriented"],"last_login":null,"login_count":59,"referral_code":"ZHkmJUsh","referred_by":"f3706a9d-f6d0-4611-9659-f07976b56cb1","subscription_tier":"pro"},"phone":"9450970442","preferences":{"language":"so","notifications":{"email":true,"in_app":false,"push":false,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":true,"show_email":false,"show_phone":false},"theme":"auto","timezone":"Pacific Standard Time (Mexico)"},"premium":true,"scores":{"activity":11.797714482249445,"engagement":58.40235517481474,"reliability":97.59493675150208,"trust":79.72247578761268},"tags":["Managed","info-mediaries","database","explicit","web-enabled"],"updated_at":"1909-02-25T16:53:46Z","username":"Rice3955","verified":true},
        \\{"address":{"city":"New Orleans","coordinates":{"latitude":79.648589,"longitude":-89.619871},"country":"Cabo Verde","postal_code":"81374","state":"Oklahoma","street":"943 New Mewsshire"},"age":30,"avatar_url":"https://picsum.photos/200/200","balance":1700.98,"bio":"Clumsy Orwellian toss mine that theirs few abroad yourselves anywhere. Outside yesterday yet back secondly yearly want of theirs what. Nightly out wait yay English oxygen because fear library terribly. Till another regiment none even from scooter library these till. Those thought man tonight tolerance these whose otherwise yours really. Has double whose set place itself those shock here sandwich. Sternly who what yearly whose its you today another does. Gleaming each perfectly easily several everything will wave she most.","birth_date":"1996-12-12","created_at":"2022-01-07T05:02:49Z","currency":"SPL","deleted_at":null,"email":"llewellynmosciski@baumbach.biz","first_name":"Mandy","gender":"female","id":"15168020-c83d-43a8-b332-5acdaf9d38ff","last_name":"Schroeder","metadata":{"failed_attempts":3,"features_enabled":["algorithm","Advanced","moderator"],"last_login":"1974-08-28T04:02:16Z","login_count":933,"referral_code":"FDnJzeop","referred_by":null,"subscription_tier":"pro"},"phone":"6783252909","preferences":{"language":"cs","notifications":{"email":true,"in_app":true,"push":false,"sms":false},"privacy":{"allow_indexing":true,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"dark","timezone":"Mid-Atlantic Standard Time"},"premium":false,"scores":{"activity":3.5651843865379855,"engagement":5.048470430045837,"reliability":17.18100105314416,"trust":78.91881016424043},"tags":["Reactive","matrix","Fully-configurable","eco-centric","Universal","mission-critical"],"updated_at":"1981-04-01T21:48:15Z","username":"Lubowitz3764","verified":false},
        \\{"address":{"city":"Cleveland","coordinates":{"latitude":68.918258,"longitude":162.03634},"country":"Tokelau","postal_code":"11509","state":"Alaska","street":"410 New Spurhaven"},"age":75,"avatar_url":"https://picsum.photos/200/200","balance":4477.61,"bio":"Company you any consequently you Romanian turn where dynasty often. Stand then practically bit horror our to aha yourself cautiously. Many ourselves leap here mile solemnly hostel shoulder for usually. A behind but your wad try itself they teach dream. Well must for of Brazilian formerly am tomorrow an they. Whom it himself for sandals that sugar soon these afterwards. Because Christian holiday early have completely however specify her for. Seldom of should whatever terribly that certain those this timing.","birth_date":"1951-04-27","created_at":"2022-06-18T04:05:36Z","currency":"CNY","deleted_at":null,"email":"nicoladaniel@durgan.io","first_name":"Henri","gender":"female","id":"dfedcaac-9b9c-4350-9d5e-448158d0f196","last_name":"Hauck","metadata":{"failed_attempts":4,"features_enabled":["multi-tasking","ability","Horizontal"],"last_login":"1919-12-29T08:51:18Z","login_count":3,"referral_code":"ERzYYLaq","referred_by":null,"subscription_tier":"pro"},"phone":"1543706598","preferences":{"language":"ks","notifications":{"email":true,"in_app":false,"push":true,"sms":false},"privacy":{"allow_indexing":true,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"dark","timezone":"Yakutsk Standard Time"},"premium":false,"scores":{"activity":15.629078559474314,"engagement":13.446378282559216,"reliability":7.468617782293049,"trust":21.46158372930243},"tags":["high-level","real-time","Ameliorated","Optional"],"updated_at":"2018-12-01T15:49:01Z","username":"Stokes1299","verified":true},
        \\{"address":{"city":"Durham","coordinates":{"latitude":22.231284,"longitude":57.926608},"country":"Aruba","postal_code":"77449","state":"New Jersey","street":"65682 Squareborough"},"age":73,"avatar_url":"https://picsum.photos/200/200","balance":9550.23,"bio":"Can switch consequently fully host than that what day smell. As everything previously next these wait jealous some yourselves her. Have all of utterly anything can how collapse bird my. There anyone here deeply you dream next company so either. Whose fact its naughty herself spin fully theirs frequently to. Back sprint whomever one there galaxy ring lucky yesterday ours. But galaxy class certain alas herself leap hard nobody one. They outside this what yet then hey Philippine spite contrary.","birth_date":"1953-11-16","created_at":"2022-02-18T09:45:15Z","currency":"USD","deleted_at":null,"email":"dennisturcotte@paucek.biz","first_name":"Maddison","gender":"female","id":"76af3fe4-7427-43b9-a26f-7787c6ad7720","last_name":"Gusikowski","metadata":{"failed_attempts":2,"features_enabled":["Automated","Expanded","internet solution"],"last_login":"1935-09-14T03:33:20Z","login_count":590,"referral_code":"KxAsjsuV","referred_by":"ab950a13-bf6d-4e32-9aa5-03032d079b4e","subscription_tier":"enterprise"},"phone":"7711075666","preferences":{"language":"ts","notifications":{"email":false,"in_app":true,"push":false,"sms":false},"privacy":{"allow_indexing":true,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"dark","timezone":"Samoa Standard Time"},"premium":false,"scores":{"activity":6.365934312792651,"engagement":21.651215972394226,"reliability":32.638892864827746,"trust":85.57037863819122},"tags":["scalable","Fundamental","background","well-modulated"],"updated_at":null,"username":"Yundt1729","verified":true},
        \\{"address":{"city":"Honolulu","coordinates":{"latitude":64.303661,"longitude":-160.048818},"country":"Christmas Island","postal_code":"56796","state":"California","street":"64496 Stravenuechester"},"age":72,"avatar_url":"https://picsum.photos/200/200","balance":7148.59,"bio":"An will lemon party cook from then smell selfish calm. Which whose every enormously person me pray that same win. Am myself e.g. one fairly they silly all group should. Defiant today weekly I today clap on even out nightly. Rhythm range monthly were at away e.g. would lastly enough. Read roughly through orchard exaltation when bevy sing permission exemplified. Theirs with read each videotape art numerous yourself nest first. When covey then onion seldom tonight Plutonian my smell hey.","birth_date":"1954-03-06","created_at":"2023-09-14T09:39:49Z","currency":"AUD","deleted_at":null,"email":"genesislangworth@hermann.net","first_name":"Alan","gender":"female","id":"f276f1d5-d9e4-4070-98f7-4818c41ce501","last_name":"Dietrich","metadata":{"failed_attempts":5,"features_enabled":["toolset","open architecture","hub"],"last_login":"1927-09-02T13:41:14Z","login_count":858,"referral_code":"bUpkKZGr","referred_by":null,"subscription_tier":"free"},"phone":"4664980253","preferences":{"language":"tw","notifications":{"email":true,"in_app":true,"push":false,"sms":true},"privacy":{"allow_indexing":true,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"dark","timezone":"UTC"},"premium":false,"scores":{"activity":66.40511549834201,"engagement":16.84112091176014,"reliability":55.18046318512053,"trust":62.121982008477026},"tags":["Polarised","Compatible","complexity","product","groupware","scalable","Digitized"],"updated_at":"1925-01-11T11:37:11Z","username":"Thompson5154","verified":false},
        \\{"address":{"city":"Phoenix","coordinates":{"latitude":-13.354006,"longitude":-167.841463},"country":"Switzerland","postal_code":"51705","state":"Maine","street":"3799 Lake Lanemouth"},"age":27,"avatar_url":"https://picsum.photos/200/200","balance":9260.76,"bio":"But sing their out those each first this belong some. For you what it dive whatever while this totally tired. His could whose both huh another clarity his wreck I. To aha temple purely these may hers despite which additionally. Myself to each wild they finally annually horror life filthy. Anyone float little shall twist owl them mourn awareness did. About itself is daily bad i.e. yesterday inside much another. Been some ride just generally i.e. any exemplified first fact.","birth_date":"1999-05-30","created_at":"2020-02-20T07:01:35Z","currency":"BTN","deleted_at":null,"email":"lilahomenick@green.org","first_name":"Stewart","gender":"male","id":"124858dc-b7cd-4a83-8ffd-85b93f4484d0","last_name":"Rogahn","metadata":{"failed_attempts":3,"features_enabled":["migration","high-level","Face to face"],"last_login":"1909-03-07T01:48:04Z","login_count":788,"referral_code":"twvQkNts","referred_by":null,"subscription_tier":"basic"},"phone":"3153796140","preferences":{"language":"sc","notifications":{"email":true,"in_app":true,"push":false,"sms":true},"privacy":{"allow_indexing":false,"profile_visible":false,"show_email":false,"show_phone":false},"theme":"dark","timezone":"Dateline Standard Time"},"premium":false,"scores":{"activity":32.57825131535684,"engagement":20.931404778021793,"reliability":81.60209040336501,"trust":23.33034686860188},"tags":["function","disintermediate","scalable","Function-based","needs-based","client-server","Re-engineered","capability"],"updated_at":"1948-01-18T11:28:53Z","username":"Steuber5940","verified":true}
        \\]
        \\}
    ;
    const result = try parseFromSlice(Export, std.testing.allocator, src, .{});
    defer result.deinit();
}
