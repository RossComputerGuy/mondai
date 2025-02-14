const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const linkage = b.option(std.builtin.LinkMode, "linkage", "The link mode");

    const options = b.addOptions();
    options.addOption([]const u8, "data_path", b.getInstallPath(.prefix, b.pathJoin(&.{ "share", "mondai" })));

    const exe = b.addExecutable(.{
        .name = "mondai",
        .root_source_file = b.path("src/mondai.zig"),
        .linkage = linkage,
        .optimize = optimize,
        .target = target,
    });

    exe.root_module.addOptions("options", options);
    b.installArtifact(exe);

    b.installDirectory(.{
        .source_dir = b.path("data"),
        .install_dir = .prefix,
        .install_subdir = b.pathJoin(&.{ "share", "mondai" }),
    });

    const step_test = b.step("test", "Run all tests");

    const exe_test = b.addTest(.{
        .root_source_file = b.path("src/mondai.zig"),
        .optimize = optimize,
        .target = b.graph.host,
    });

    const run_test = b.addRunArtifact(exe_test);
    step_test.dependOn(&run_test.step);
}
