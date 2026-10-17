const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // simdjson as a static C library
    // Always make this optimized for ReleaseFast, since no one's going to be debugging
    // it from here and simdjson assumes heavy inlining to avoid being super slow.
    const simdjson_cpp_mod = b.createModule(.{ .target = target, .optimize = .fast, .link_libcpp = true });
    simdjson_cpp_mod.addCSourceFile(.{ .file = b.path("vendor/simdjson.cpp") });
    simdjson_cpp_mod.addCSourceFile(.{ .file = b.path("src/sj.cpp") });
    const simdjson_cpp_lib = b.addLibrary(.{
        .name = "simdjson",
        .linkage = .static,
        .root_module = simdjson_cpp_mod,
    });

    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/sj.h"),
        .target = target,
        .optimize = .fast,
    });

    const mod = b.addModule("simdjson", .{
        .root_source_file = b.path("src/simdjson.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "simdjson_c", .module = translator.mod }},
    });
    mod.linkLibrary(simdjson_cpp_lib);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function.
    const exe = b.addExecutable(.{
        .name = "simdjson",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "simdjson", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Docs are generated from a compile step, so make a throwaway library
    // around the public module.
    const docs_lib = b.addLibrary(.{
        .name = "docs",
        .root_module = mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
