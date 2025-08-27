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
    const demo: A = .{
        .a = 10,
        .b = 20,
    };

    var x = demo;
    x.a = 1000;

    std.debug.print("{any}\n {any}\n", .{ demo, x });
}
