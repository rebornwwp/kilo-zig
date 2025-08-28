//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

var allocator: std.mem.Allocator = undefined;
const self = @This();
const A = struct {
    a: std.ArrayList(u8),
};

var ab: A = undefined;

fn func1(a: *A) !void {
    a.a.deinit();
    a.a = std.ArrayList(u8).init(self.allocator);
    try a.a.appendSlice("ehllwl");
}

fn init() void {
    self.ab = .{ .a = std.ArrayList(u8).init(self.allocator) };
}

fn deinit() void {
    ab.a.deinit();
}

fn hello() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    self.allocator = gpa.allocator();
    self.init();
    defer self.deinit();

    try func1(&self.ab);
}

test "hello world" {
    try hello();
    // var a = std.ArrayList(u8).init(allocator);

    // // const x = "hello world";
    // try a.appendSlice("hello world");
    // const b = try a.clone();
    // defer b.deinit();

    // std.debug.print("a {s}\n", .{a.items});
    // a.deinit();
    // a = std.ArrayList(u8).init(allocator);
    // try a.appendSlice("hello wo");
    // defer a.deinit();
    // std.debug.print("a {s}\n", .{a.items});

    // std.debug.print("b {s}\n", .{b.items});
}
