const std = @import("std");

const MondaiOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: ?std.builtin.LinkMode,
    data_path: []const u8,
};

const TopLevelStep = struct {
    pub const base_id: std.Build.Step.Id = .top_level;

    step: std.Build.Step,
    description: []const u8,
};

fn addMondai(b: *std.Build, opts: MondaiOptions) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "data_path", opts.data_path);

    const exe = b.addExecutable(.{
        .name = "mondai",
        .root_source_file = b.path("src/mondai.zig"),
        .linkage = opts.linkage,
        .optimize = opts.optimize,
        .target = opts.target,
    });

    exe.root_module.addOptions("options", options);
    return exe;
}

fn scanTests(b: *std.Build, step: *std.Build.Step, dir: std.fs.Dir, exe: *std.Build.Step.Compile, path: []const u8, depth: usize) void {
    var iter = dir.iterate();
    while (iter.next() catch |err| std.debug.panic("Failed to iterate: {}", .{err})) |entry| {
        if (entry.kind == .directory) {
            const child_test = blk: {
                const step_info = b.allocator.create(TopLevelStep) catch @panic("OOM");
                step_info.* = .{
                    .step = std.Build.Step.init(.{
                        .id = TopLevelStep.base_id,
                        .name = b.dupe(entry.name),
                        .owner = b,
                    }),
                    .description = b.fmt("Tests for {s}", .{entry.name}),
                };
                break :blk &step_info.step;
            };

            var child_dir = dir.openDir(entry.name, .{
                .iterate = true,
            }) catch |err| std.debug.panic("Cannot open dir: {}", .{err});
            defer child_dir.close();

            scanTests(b, child_test, child_dir, exe, b.pathJoin(&.{ path, entry.name }), depth + 1);

            step.dependOn(child_test);
        }

        if (depth > 1 and !std.mem.endsWith(u8, entry.name, ".expect") and entry.kind == .file) {
            const test_run = b.addRunArtifact(exe);

            test_run.addArg(b.pathJoin(&.{ path, entry.name }));

            var test_run_result_file = dir.openFile(b.fmt("{s}.expect", .{path}), .{}) catch |err| std.debug.panic("Cannot open file \"{s}.expect\": {}", .{ path, err });
            defer test_run_result_file.close();

            const test_run_result = test_run_result_file.readToEndAlloc(b.allocator, (test_run_result_file.metadata() catch |err| std.debug.panic("Cannot read metata: {}", .{err})).size()) catch |err| std.debug.panic("Failed to read: {}", .{err});
            defer b.allocator.free(test_run_result);

            test_run.expectStdOutEqual(test_run_result);
            step.dependOn(&test_run.step);
        }
    }
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const linkage = b.option(std.builtin.LinkMode, "linkage", "The link mode");

    const exe = addMondai(b, .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .data_path = b.getInstallPath(.prefix, b.pathJoin(&.{ "share", "mondai" })),
    });
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

    const host_exe = addMondai(b, .{
        .target = b.graph.host,
        .optimize = optimize,
        .linkage = linkage,
        .data_path = b.pathFromRoot("data"),
    });

    var test_dir = std.fs.openDirAbsolute(b.pathFromRoot("tests"), .{
        .iterate = true,
    }) catch |err| std.debug.panic("Failed to open dir: {}", .{err});
    defer test_dir.close();

    scanTests(b, step_test, test_dir, host_exe, b.pathFromRoot("tests"), 0);
}
