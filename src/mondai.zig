const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const assert = std.debug.assert;
const Template = @import("mondai/Template.zig");
const Issue = @import("mondai/Issue.zig");
const Source = @import("mondai/Source.zig");

fn processFile(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    path: []const u8,
    source: Source,
    data_issues: std.StringHashMap(Template.TokenSlice),
    scratch: *std.ArrayList(u8),
    issues: *std.ArrayList(Issue),
    writer: anytype,
) !void {
    const metadata = try file.metadata();

    try file.reader().readAllArrayList(scratch, metadata.size());
    defer scratch.clearRetainingCapacity();

    const comments = try source.scan(scratch.items);
    defer alloc.free(comments);

    var iter = data_issues.iterator();
    while (iter.next()) |issue_entry| {
        try Issue.scan(issue_entry.value_ptr.*, comments, issues);
        defer issues.clearRetainingCapacity();

        if (issues.items.len > 0) {
            try writer.writeAll(path);
            try writer.writeAll(":\n");

            for (issues.items) |issue| {
                try writer.writeAll("  - ");
                try Template.format(writer, issue_entry.value_ptr.*, issue);
                try writer.writeAll("\n");
            }
        }
    }
}

fn mainWithAlloc(alloc: std.mem.Allocator) !void {
    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    defer stdout.flush() catch |err| std.debug.panic("Failed to flush stdout: {}", .{err});

    const stderr = std.io.getStdErr().writer();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.skip();

    var root_dir_path = try std.process.getCwdAlloc(alloc);
    defer alloc.free(root_dir_path);

    var exclude_exts = std.ArrayList([]const u8).init(alloc);
    defer {
        for (exclude_exts.items) |item| alloc.free(item);
        exclude_exts.deinit();
    }

    const data_path = try alloc.dupe(u8, options.data_path);
    defer alloc.free(data_path);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.writer().writeAll(
                \\mondai [options] [path]
                \\
                \\Options:
                \\  --help, -h              Print help
                \\  --exclude-extensions    A comma separated list of file extensions to exclude.
                \\  --data-path             Specifies the path to lookup the data for issue formats and source comment formats.
                \\
            );
            return;
        } else if (std.mem.eql(u8, arg, "--exclude-extensions")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            var s = std.mem.splitAny(u8, value, ",");

            while (s.next()) |item| {
                const item_dupe = try alloc.dupe(u8, item);
                errdefer alloc.free(item_dupe);
                try exclude_exts.append(item_dupe);
            }
        } else if (std.mem.eql(u8, arg, "--data-path")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            root_dir_path = try alloc.dupe(u8, value);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            alloc.free(root_dir_path);
            root_dir_path = try alloc.dupe(u8, arg);
        } else {
            try stderr.print("mondai: invalid argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    var data_dir = if (std.fs.path.isAbsolute(data_path)) try std.fs.openDirAbsolute(data_path, .{
        .iterate = true,
    }) else try std.fs.cwd().openDir(data_path, .{
        .iterate = true,
    });
    defer data_dir.close();

    var data_sources_dir = try data_dir.openDir("sources", .{
        .iterate = true,
    });
    defer data_sources_dir.close();

    var data_sources = try Source.readDir(alloc, data_sources_dir);
    defer {
        var iter = data_sources.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.destroy();
        }
        data_sources.deinit();
    }

    var data_issues_dir = try data_dir.openDir("issues", .{
        .iterate = true,
    });
    defer data_issues_dir.close();

    var data_issues = try Issue.readDir(alloc, data_issues_dir);
    defer {
        var iter = data_issues.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |item| item.deinit(alloc);
            alloc.free(entry.value_ptr.*);
        }
        data_issues.deinit();
    }

    var scratch = std.ArrayList(u8).init(alloc);
    defer scratch.deinit();

    var issues = std.ArrayList(Issue).init(alloc);
    defer issues.deinit();

    var root_dir = (if (std.fs.path.isAbsolute(root_dir_path)) std.fs.openDirAbsolute(root_dir_path, .{
        .iterate = true,
    }) else std.fs.cwd().openDir(root_dir_path, .{
        .iterate = true,
    })) catch |err| switch (err) {
        error.NotDir => {
            var file = if (std.fs.path.isAbsolute(root_dir_path)) try std.fs.openFileAbsolute(root_dir_path, .{}) else try std.fs.cwd().openFile(root_dir_path, .{});
            defer file.close();

            const file_ext = blk: {
                const tmp = std.fs.path.extension(root_dir_path);
                break :blk tmp[@min(tmp.len, 1)..];
            };

            if (data_sources.get(file_ext)) |source| {
                try processFile(alloc, file, root_dir_path, source, data_issues, &scratch, &issues, stdout.writer());
            }
            return;
        },
        else => return err,
    };
    defer root_dir.close();

    var walker = try root_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const file_ext = blk: {
            const tmp = std.fs.path.extension(entry.path);
            break :blk tmp[@min(tmp.len, 1)..];
        };

        if (!data_sources.contains(file_ext)) continue;

        for (exclude_exts.items) |ext| {
            if (std.mem.eql(u8, ext, file_ext)) continue;
        }

        const source = data_sources.get(file_ext) orelse continue;

        var file = try root_dir.openFile(entry.path, .{});
        defer file.close();

        try processFile(alloc, file, entry.path, source, data_issues, &scratch, &issues, stdout.writer());
    }
}

pub fn main() !void {
    if (builtin.mode == .Debug) {
        var debug_alloc = std.heap.DebugAllocator(.{}).init;
        defer assert(debug_alloc.deinit() == .ok);
        return try mainWithAlloc(debug_alloc.allocator());
    } else {
        return try mainWithAlloc(std.heap.smp_allocator);
    }
}

test {
    _ = Template;
    _ = Issue;
    _ = Source;
}
