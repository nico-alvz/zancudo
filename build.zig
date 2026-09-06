const std = @import("std");

/// Build graph for the Zancudo MQTT broker.
///
/// Steps:
///   zig build            -> compile the broker executable
///   zig build run        -> compile and start the broker
///   zig build test       -> run the unit-test suite
///   zig build fuzz       -> build the frame-decoder fuzz harness
///
/// Options:
///   -Dsanitize=true      -> turn on the UndefinedBehaviorSanitizer trap handler
///                           and (for any linked C) the AddressSanitizer.
///   -Dio-backend=epoll   -> force a specific reactor backend at compile time
///                           (auto | io_uring | epoll | kqueue).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize = b.option(bool, "sanitize", "Enable ASan (C) + UBSan trap handler") orelse false;
    const io_backend = b.option([]const u8, "io-backend", "auto|io_uring|epoll|kqueue") orelse "auto";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "io_backend", io_backend);
    build_options.addOption(bool, "sanitize", sanitize);

    // ----- broker executable -------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "zancudo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", build_options);
    if (sanitize) {
        // Zig code already traps on UB in Debug/ReleaseSafe; this also arms
        // AddressSanitizer for any C/C++ translation unit that gets linked in.
        exe.root_module.sanitize_c = true;
        exe.root_module.sanitize_thread = false;
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the broker");
    run_step.dependOn(&run_cmd.step);

    // ----- unit tests ------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("test_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addOptions("build_options", build_options);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ----- fuzz harness --------------------------------------------------
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol_lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz-decoder",
        .root_source_file = b.path("fuzz/fuzz_decoder.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_exe.root_module.addOptions("build_options", build_options);
    fuzz_exe.root_module.addImport("protocol", protocol_mod);
    const fuzz_step = b.step("fuzz", "Build the frame-decoder fuzz harness");
    fuzz_step.dependOn(&b.addInstallArtifact(fuzz_exe, .{}).step);
}
