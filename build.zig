const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `version --verbose` reports the commit: `-Dcommit=<sha>` wins (CI),
    // else `git rev-parse --short HEAD` at configure time, else `unknown`.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "commit", b.option(
        []const u8,
        "commit",
        "Commit id reported by `ifnh version --verbose` (default: git rev-parse --short HEAD)",
    ) orelse gitShortHead(b));

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .omit_frame_pointer = optimize != .Debug,
        .error_tracing = false,
    });

    module.addOptions("build_options", build_options);

    // The published JSON Schema lives in docs/ (outside src/); embed it by import.
    module.addAnonymousImport("config_schema", .{
        .root_source_file = b.path("docs/config.schema.json"),
    });

    const exe = b.addExecutable(.{
        .name = "ifnh",
        .root_module = module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run ifnh");
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // `zig build check`: analyze the whole program without emitting a binary
    // (cheap type-check loop; the same idiom ZLS build-on-save uses). This
    // compile step is never installed, so no codegen is requested for it.
    const check_exe = b.addExecutable(.{
        .name = "ifnh",
        .root_module = module,
    });
    const check_step = b.step("check", "Type-check without emitting a binary");
    check_step.dependOn(&check_exe.step);

    // `zig build test -Dtest-filter=<substr>` runs only matching tests.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains this substring (repeatable)",
    ) orelse &.{};
    const unit_tests = b.addTest(.{
        .root_module = module,
        .filters = test_filters,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // libifnh (E-06b): the runtime as a static library with a C ABI. The
    // module links libc for the exported symbols (`malloc`, `environ`); the
    // executable does not.
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .link_libc = true,
        .error_tracing = false,
    });
    lib_module.addOptions("build_options", build_options);
    lib_module.addAnonymousImport("config_schema", .{
        .root_source_file = b.path("docs/config.schema.json"),
    });
    const lib = b.addLibrary(.{
        .name = "ifnh",
        .linkage = .static,
        .root_module = lib_module,
    });
    lib.installHeader(b.path("include/ifnh.h"), "ifnh.h");
    b.installArtifact(lib);
    const lib_step = b.step("lib", "Build libifnh.a and install include/ifnh.h");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

    // `check` also type-checks the library (never installed, no codegen).
    const check_lib = b.addLibrary(.{
        .name = "ifnh",
        .linkage = .static,
        .root_module = lib_module,
    });
    check_step.dependOn(&check_lib.step);

    // The library pulls in most of the tree, whose tests the main test
    // binary already runs; by default only lib.zig's own tests run here.
    const lib_tests = b.addTest(.{
        .root_module = lib_module,
        .filters = if (test_filters.len > 0) test_filters else &.{"lib.test."},
    });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}

/// `git rev-parse --short HEAD` in the build root; `unknown` when git or
/// `.git` is missing (source tarballs, unusual checkouts).
fn gitShortHead(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(
        &.{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--short", "HEAD" },
        &code,
        .ignore,
    ) catch return "unknown";
    const sha = std.mem.trim(u8, out, " \t\r\n");
    return if (code == 0 and sha.len > 0) sha else "unknown";
}
