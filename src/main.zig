const std = @import("std");
const Io = std.Io;

const sj = @import("simdjson_zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const f = try std.Io.Dir.cwd().readFileAlloc(io, "data_1gb.json", init.gpa, .unlimited);
    defer gpa.free(f);

    // const Export = struct {
    //     metadata: Metadata,
    //     users: []User,

    //     const Metadata = struct {
    //         configuration: Configuration,
    //         generated_at: []const u8, // ISO 8601 with offset
    //         generator: []const u8,
    //         schema_version: u32,
    //         statistics: Statistics,
    //         version: []const u8,
    //     };

    //     const Configuration = struct {
    //         checksum_algo: []const u8,
    //         compression: ?[]const u8,
    //         encryption: bool,
    //         export_settings: ExportSettings,
    //         include_nulls: bool,
    //         locale: []const u8,
    //         pretty_print: bool,
    //         source_systems: [][]const u8,
    //     };

    //     const ExportSettings = struct {
    //         batch_size: u32,
    //         retry_attempts: u32,
    //         timeout_seconds: u32,
    //     };

    //     const Statistics = struct {
    //         processing_time: ?f64, // null in the sample; adjust if it's really something else
    //         total_records: u64,
    //         validation_score: f64,
    //     };

    //     const User = struct {
    //         address: Address,
    //         age: u32,
    //         avatar_url: []const u8,
    //         balance: f64,
    //         bio: []const u8,
    //         birth_date: []const u8, // "YYYY-MM-DD"
    //         created_at: []const u8,
    //         currency: []const u8,
    //         deleted_at: ?[]const u8,
    //         email: []const u8,
    //         first_name: []const u8,
    //         gender: []const u8,
    //         id: []const u8, // UUID
    //         last_name: []const u8,
    //         metadata: UserMetadata,
    //         phone: []const u8, // string in the sample; keep as text to preserve leading zeros
    //         preferences: Preferences,
    //         premium: bool,
    //         scores: Scores,
    //         tags: [][]const u8,
    //         updated_at: ?[]const u8,
    //         username: []const u8,
    //         verified: bool,
    //     };

    //     const Address = struct {
    //         city: []const u8,
    //         coordinates: Coordinates,
    //         country: []const u8,
    //         postal_code: []const u8,
    //         state: []const u8,
    //         street: []const u8,
    //     };

    //     const Coordinates = struct {
    //         latitude: f64,
    //         longitude: f64,
    //     };

    //     const UserMetadata = struct {
    //         failed_attempts: u32,
    //         features_enabled: [][]const u8,
    //         last_login: ?[]const u8,
    //         login_count: u32,
    //         referral_code: []const u8,
    //         referred_by: ?[]const u8,
    //         subscription_tier: []const u8,
    //     };

    //     const Preferences = struct {
    //         language: []const u8,
    //         notifications: Notifications,
    //         privacy: Privacy,
    //         theme: []const u8,
    //         timezone: []const u8,
    //     };

    //     const Notifications = struct {
    //         email: bool,
    //         in_app: bool,
    //         push: bool,
    //         sms: bool,
    //     };

    //     const Privacy = struct {
    //         allow_indexing: bool,
    //         profile_visible: bool,
    //         show_email: bool,
    //         show_phone: bool,
    //     };

    //     const Scores = struct {
    //         activity: f64,
    //         engagement: f64,
    //         reliability: f64,
    //         trust: f64,
    //     };
    // };

    // var iter = init.minimal.args.iterate();
    // std.debug.assert(iter.skip());
    // const run_stdlib = iter.next() orelse "0";
    // if (std.mem.eql(u8, run_stdlib, "0")) {
    //     std.debug.print("Using stdlib\n", .{});
    //     const parsed = try std.json.parseFromSlice(Export, gpa, f, .{ .ignore_unknown_fields = true });
    //     defer parsed.deinit();
    //     std.debug.print("{} items\n", .{parsed.value.users.len});
    // } else {
    // std.debug.print("Using simdjson\n", .{});
    // const parsed = try sj.parseFromSlice(Export, gpa, f, .{ .ignore_unknown_fields = true });
    // defer parsed.deinit();
    // std.debug.print("{} items\n", .{parsed.value.users.len});
    // }

    var output = try gpa.alloc(u8, f.len);
    _ = try sj.minify(f, output);
    std.debug.print("{s}", .{output[0..400]});
}
