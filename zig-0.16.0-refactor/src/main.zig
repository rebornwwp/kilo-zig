const std = @import("std");
const posix = std.posix;
const Editor = @import("Editor.zig");

var editor: Editor = undefined;

fn handleSigWinCh(_: std.c.SIG) callconv(.c) void {
    editor.handleResize();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);

    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(io, "Usage: kilo <filename>\n");
        std.process.exit(1);
    }

    editor = try Editor.init(allocator, io);
    defer editor.deinit();

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigWinCh },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(std.c.SIG.WINCH, &sa, null);

    try editor.open(args[1]);
    try editor.term.enableRawMode();
    defer editor.term.disableRawMode();

    editor.setStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find");

    while (true) {
        editor.refreshScreen();
        if (!editor.processKeypress()) {
            editor.term.disableRawMode();
            std.process.exit(0);
        }
    }
}
