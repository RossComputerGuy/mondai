const std = @import("std");
const Template = @import("Template.zig");
const Allocator = std.mem.Allocator;
const Issue = @This();

owner: []const u8,
repo: []const u8,
issue: usize,

pub fn read(alloc: Allocator, file: std.fs.File) !Template.TokenSlice {
    const metadata = try file.metadata();

    const buff = try file.readToEndAlloc(alloc, metadata.size());
    defer alloc.free(buff);

    return try Template.parse(alloc, buff[0..(std.mem.indexOf(u8, buff, "\n") orelse buff.len)], true);
}

pub fn readDir(alloc: Allocator, dir: std.fs.Dir) !std.StringHashMap(Template.TokenSlice) {
    var map = std.StringHashMap(Template.TokenSlice).init(alloc);
    errdefer {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |item| item.deinit(alloc);
            alloc.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        var file = try dir.openFile(entry.name, .{});
        defer file.close();

        const source = try read(alloc, file);
        errdefer {
            for (source) |item| item.deinit(alloc);
            alloc.free(source);
        }

        const key = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(key);

        try map.put(key, source);
    }
    return map;
}

pub fn scan(slice: Template.TokenSlice, comments: []const []const u8, list: *std.ArrayList(Issue)) !void {
    for (comments) |comment| {
        var i: usize = 0;
        while (i < comment.len) : (i += 1) {
            try list.append(try Template.match(Issue, slice, comment[i..(std.mem.indexOfPos(u8, comment, i, "\n") orelse comment.len)], &i) orelse continue);
            i -= 1;
        }
    }
}
