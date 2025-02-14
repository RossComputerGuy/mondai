const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const Template = @This();

pub const Token = union(enum) {
    variable: []const u8,
    text: []const u8,

    pub fn value(self: Token) []const u8 {
        return switch (self) {
            .variable => |variable| variable,
            .text => |text| text,
        };
    }

    pub fn deinit(self: Token, alloc: Allocator) void {
        return alloc.free(self.value());
    }

    pub fn format(self: Token, comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        switch (self) {
            .variable => |variable| {
                try writer.writeByte('%');
                try writer.writeAll(variable);
                try writer.writeByte('%');
            },
            .text => |text| try writer.writeAll(text),
        }
    }
};

pub const TokenSlice = []const Token;

pub fn parse(alloc: Allocator, source: []const u8, dupe: bool) !TokenSlice {
    var list = std.ArrayList(Token).init(alloc);
    defer {
        if (dupe) {
            for (list.items) |item| item.deinit(alloc);
        }
        list.deinit();
    }

    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (std.mem.indexOfPos(u8, source, i, "%")) |start| {
            const pre = source[i..start];

            if (pre.len > 0) {
                try list.append(.{
                    .text = if (dupe) try alloc.dupe(u8, pre) else pre,
                });
                i += pre.len;
            }

            if (std.mem.indexOfPos(u8, source, start + 1, "%")) |end| {
                const slice = source[(start + 1)..end];
                try list.append(.{
                    .variable = if (dupe) try alloc.dupe(u8, slice) else slice,
                });
                i += slice.len + 1;
            }
        } else {
            const slice = source[i..];

            try list.append(.{
                .text = if (dupe) try alloc.dupe(u8, slice) else slice,
            });

            i += slice.len;
        }
    }

    return try list.toOwnedSlice();
}

pub fn format(writer: anytype, slice: TokenSlice, args: anytype) @TypeOf(writer).Error!void {
    for (slice) |item| {
        switch (item) {
            .variable => |variable| {
                inline for (comptime std.meta.fields(@TypeOf(args))) |field| {
                    if (std.mem.eql(u8, variable, field.name)) {
                        const value = @field(args, field.name);
                        const T = @TypeOf(value);

                        if (T == []const u8) {
                            try writer.writeAll(value);
                        } else {
                            try writer.print("{any}", .{value});
                        }
                    }
                }
            },
            .text => |text| try writer.writeAll(text),
        }
    }
}

pub fn match(
    comptime T: type,
    slice: TokenSlice,
    buff: []const u8,
    out_off_ptr: ?*usize,
) !?T {
    var self: T = undefined;

    var i: usize = 0;
    for (slice, 0..) |item, x| {
        const is_last = (slice.len - 1) == x;
        switch (item) {
            .variable => |variable| {
                inline for (comptime std.meta.fields(T)) |field| {
                    if (std.mem.eql(u8, variable, field.name)) {
                        const FieldType = field.type;

                        @field(self, field.name) = switch (FieldType) {
                            []const u8 => blk: {
                                const chunk = buff[i..((if (!is_last) std.mem.indexOfPos(u8, buff, i, slice[x + 1].text) else null) orelse buff.len)];
                                i += chunk.len;
                                break :blk chunk;
                            },
                            else => switch (@typeInfo(FieldType)) {
                                .int => blk: {
                                    const chunk = buff[i..(blk2: {
                                        for (i..buff.len) |y| {
                                            if (!std.ascii.isDigit(buff[y])) break :blk2 y;
                                        }
                                        break :blk2 buff.len;
                                    })];
                                    i += chunk.len;
                                    break :blk std.fmt.parseInt(FieldType, chunk, 10) catch return null;
                                },
                                else => @compileError("Cannot match type " ++ @typeName(FieldType)),
                            },
                        };
                    }
                }
            },
            .text => |text| {
                if (buff.len < i + text.len) return null;

                const chunk = buff[i..(i + text.len)];
                if (!std.mem.eql(u8, chunk, text)) return null;

                i += chunk.len;
            },
        }
    }

    if (out_off_ptr) |out_off| out_off.* += i;
    return self;
}

test "Parsing C-style" {
    const slice = try parse(std.testing.allocator, "/* %value% */", false);
    defer std.testing.allocator.free(slice);

    try expectEqualDeep(&[_]Token{
        .{ .text = "/* " },
        .{ .variable = "value" },
        .{ .text = " */" },
    }, slice);
}

test "Parsing GitHub" {
    const slice = try parse(std.testing.allocator, "https://github.com/%owner%/%repo%/issues/%issue%", false);
    defer std.testing.allocator.free(slice);

    try expectEqualDeep(&[_]Token{
        .{ .text = "https://github.com/" },
        .{ .variable = "owner" },
        .{ .text = "/" },
        .{ .variable = "repo" },
        .{ .text = "/issues/" },
        .{ .variable = "issue" },
    }, slice);
}

test "Formatting" {
    const slice = try parse(std.testing.allocator, "Hello, %name%", false);
    defer std.testing.allocator.free(slice);

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try format(output.writer(), slice, .{
        .name = @as([]const u8, "world"),
    });

    try expectEqualStrings("Hello, world", output.items);
}

test "Match" {
    const slice = try parse(std.testing.allocator, "https://github.com/%owner%/%repo%/issues/%issue%", false);
    defer std.testing.allocator.free(slice);

    const m = try match(struct {
        owner: []const u8,
        repo: []const u8,
        issue: usize,
    }, slice, "https://github.com/ziglang/zig/issues/1", null) orelse return error.NotMatched;

    try expectEqualStrings("ziglang", m.owner);
    try expectEqualStrings("zig", m.repo);
    try expectEqual(1, m.issue);
}
