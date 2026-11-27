const std = @import("std");
const Io = std.Io;
const sj = @import("simdjson");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2 or args.len > 3) {
        const exe_name = if (args.len >= 1) args[0] else "simdjson";
        try usage(io, exe_name);
        return 1;
    }

    var use_std_lib = false;
    var subcommand_index: usize = 1;

    if (args.len == 3) {
        if (std.mem.eql(u8, args[1], "--use-std-lib")) {
            use_std_lib = true;
            subcommand_index = 2;
        } else {
            var writer = Io.File.stderr().writer(io, &.{});
            const stderr = &writer.interface;
            try stderr.print("\"{s}\" is not a valid option.\n\nOptions are:\n  --use-std-lib: Use std.json for parsing rather than simdjson.\n", .{args[1]});
            return 1;
        }
    }

    const subcommand = std.meta.stringToEnum(Subcommand.Type, args[subcommand_index]) orelse {
        var writer = Io.File.stderr().writer(io, &.{});
        const stderr = &writer.interface;
        try stderr.print("\"{s}\" is not a valid subcommand.\n\nOptions are:\n{s}\n", .{ args[subcommand_index], Subcommands.usage("  ") });

        return 1;
    };

    switch (subcommand) {
        .validate => {
            const input = try readStdin(allocator, io);
            defer allocator.free(input);

            var is_valid: bool = undefined;
            if (use_std_lib) {
                is_valid = try std.json.Scanner.validate(allocator, input);
            } else {
                is_valid = try sj.validate(allocator, input);
            }

            if (is_valid) {
                try Io.File.stdout().writeStreamingAll(io, "true\n");
                return 0;
            } else {
                try Io.File.stdout().writeStreamingAll(io, "false\n");
                return 1;
            }
        },
        .minify => {
            const input = try readStdin(allocator, io);
            defer allocator.free(input);

            var minified: []u8 = undefined;
            const out_buf = try allocator.alloc(u8, input.len);
            defer allocator.free(out_buf);
            if (use_std_lib) {
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{ .duplicate_field_behavior = .use_last, .parse_numbers = false });
                defer parsed.deinit();
                var writer = std.Io.Writer.fixed(out_buf);
                try std.json.Stringify.value(parsed.value, .{ .whitespace = .minified }, &writer);
                minified = writer.buffered();
            } else {
                minified = try sj.minify(input, out_buf);
            }

            try Io.File.stdout().writeStreamingAll(io, minified);
            try Io.File.stdout().writeStreamingAll(io, "\n");
            return 0;
        },
        .parse_twitter => {
            const input = try readFile(allocator, io, "twitter.json");
            defer allocator.free(input);

            if (use_std_lib) {
                for (0..10000) |_| {
                    const parsed = try std.json.parseFromSlice(TwitterData, allocator, input, .{ .ignore_unknown_fields = true });
                    defer parsed.deinit();
                }
            } else {
                const parser = try sj.TapeParser.init(allocator, .{});
                defer parser.deinit();
                for (0..10000) |_| {
                    var token_source = sj.TapeTokenSource.initWithParser(allocator, parser, input);
                    defer token_source.deinit();
                    const parsed = try std.json.parseFromTokenSource(TwitterData, allocator, &token_source, .{ .ignore_unknown_fields = true });
                    defer parsed.deinit();
                }
            }

            return 0;
        },
    }
}

const User = struct {
    id: u64,
    name: []u8,
    screen_name: []u8,
    location: []u8,
    description: []u8,
    verified: bool,
    followers_count: u64,
    friends_count: u64,
    statuses_count: u64,
};

const Status = struct {
    created_at: []u8,
    id: u64,
    text: []u8,
    user: User,
    retweet_count: u64,
    favorite_count: u64,
};

const TwitterData = struct {
    statuses: []Status,
};

// Caller owns returned slice.
fn readFile(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .unlimited);
}

// Caller owns returned slice.
fn readStdin(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    const stdin = &reader.interface;
    const input = try stdin.readAllocShort(allocator, 2_000_000_000);
    try ensureEndOfStream(stdin);
    return input;
}

// Ensures there are no bytes left in the stream. If there are, or we can't determine
// if there are, this returns an error.
fn ensureEndOfStream(reader: *std.Io.Reader) error{ InputTooLong, ReadFailed }!void {
    _ = reader.peek(1) catch |err| {
        switch (err) {
            error.EndOfStream => return {},
            error.ReadFailed => return error.ReadFailed,
        }
    };

    return error.InputTooLong;
}

fn usage(io: Io, exe_name: []const u8) !void {
    const subcommands = Subcommands.usage("  ");
    var writer = Io.File.stderr().writer(io, &.{});
    const stderr = &writer.interface;
    try stderr.print("Usage: {s} [options] <subcommand>\n\nOptions:\n  --use-std-lib: Use std.json for parsing rather than simdjson.\n\nSubcommands:\n{s}\n\nAll subcommands take input from stdin (reading until EOF), and write output and errors to stdout and stderr, respectively.\nRedirect from these as needed.\n", .{ exe_name, subcommands });
}

const Subcommand = struct {
    type: Type,
    description: []const u8,

    const Type = enum { validate, minify, parse_twitter };
};

const Subcommands = struct {
    const commands = [_]Subcommand{
        .{ .type = .validate, .description = "return 0 if valid JSON, otherwise 1. Outputs true or false on stdout." },
        .{ .type = .minify, .description = "return 0 on success, otherwise non 0. Outputs minified JSON on stdout." },
        .{ .type = .parse_twitter, .description = "return 0 it can parse twitter.json into TwitterData, otherwise non 0." },
    };

    fn usage(comptime leading: []const u8) []const u8 {
        const s = block: {
            comptime var buffer: []const u8 = "";

            inline for (commands) |command| {
                buffer = buffer ++ leading ++ @tagName(command.type) ++ ": " ++ command.description ++ "\n";
            }

            // Trim the trailing newline
            break :block buffer[0 .. buffer.len - 1];
        };
        return s;
    }
};
