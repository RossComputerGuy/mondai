const std = @import("std");
const Template = @import("Template.zig");
const Allocator = std.mem.Allocator;
const Source = @This();

allocator: Allocator,
single_line: ?Template.TokenSlice,
multi_line: ?Template.TokenSlice,

const fields: []const struct { []const u8, []const u8 } = &.{
    .{ "single-line", "single_line" },
    .{ "multi-line", "multi_line" },
};

pub fn read(alloc: Allocator, file: std.fs.File) !Source {
    var self = Source{
        .allocator = alloc,
        .single_line = null,
        .multi_line = null,
    };

    inline for (fields) |field| {
        var line = std.ArrayList(u8).init(alloc);
        defer line.deinit();

        file.reader().streamUntilDelimiter(line.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };

        if (line.items.len == 0) break;

        const split = std.mem.indexOf(u8, line.items, ":") orelse return error.MissingDelimiter;
        if (!std.mem.eql(u8, line.items[0..split], field[0])) return error.InvalidField;

        @field(self, field[1]) = try Template.parse(alloc, line.items[(split + 2)..(std.mem.indexOf(u8, line.items, "\n") orelse line.items.len)], true);
    }

    return self;
}

pub fn readDir(alloc: Allocator, dir: std.fs.Dir) !std.StringHashMap(Source) {
    var map = std.StringHashMap(Source).init(alloc);
    errdefer {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.destroy();
        }
        map.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        var file = try dir.openFile(entry.name, .{});
        defer file.close();

        const source = try read(alloc, file);
        errdefer source.destroy();

        const key = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(key);

        try map.put(key, source);
    }
    return map;
}

pub fn destroy(self: Source) void {
    if (self.single_line) |single_line| {
        for (single_line) |item| item.deinit(self.allocator);
        self.allocator.free(single_line);
    }

    if (self.multi_line) |multi_line| {
        for (multi_line) |item| item.deinit(self.allocator);
        self.allocator.free(multi_line);
    }
}

const Comment = struct {
    content: []const u8,
};

pub fn scan(self: Source, buff: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(self.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < buff.len) : (i += 1) {
        if (self.single_line) |single_line| {
            const m = try Template.match(Comment, single_line, buff[i..(std.mem.indexOfPos(u8, buff, i, "\n") orelse buff.len)], &i) orelse continue;
            i -= 1;
            try list.append(m.content);
        }
        if (self.multi_line) |multi_line| {
            const m = try Template.match(Comment, multi_line, buff[i..], &i) orelse continue;
            i -= 1;
            try list.append(m.content);
        }
    }

    return try list.toOwnedSlice();
}
