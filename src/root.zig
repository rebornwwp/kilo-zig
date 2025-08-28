//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

const A = struct {
    a: usize,
    b: usize,
};
test "hello world" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var a = std.ArrayList(u8).init(allocator);
    defer a.deinit();

    // const x = "hello world";
    try a.appendSlice("hello world");
    const b = try a.clone();
    defer b.deinit();

    std.debug.print("a {s}\n", .{a.items});
    std.debug.print("b {s}\n", .{b.items});
}
