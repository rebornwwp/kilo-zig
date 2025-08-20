const ctrl_q = 0x11;

var EditorConfig = struct {
    termios: posix.termios,
};

var E: EditorConfig = {};

fn enableRawMode() !std.posix.termios {
    const orig_term = try posix.tcgetattr(posix.STDIN_FILENO);
    var term = orig_term;

    term.iflag.IXON = false; // ctrl-S + ctrl-Q
    term.iflag.ICRNL = false;
    term.iflag.BRKINT = false;
    term.iflag.INPCK = false;
    term.iflag.ISTRIP = false;

    term.oflag.OPOST = false;

    term.cflag.CSIZE = .CS8;

    term.lflag.ICANON = false; // 关闭cannonical mode
    term.lflag.ECHO = false;
    term.lflag.ISIG = false; // ctrl-C + ctrl-Z 屏蔽
    term.lflag.IEXTEN = false; //ctrl-V

    term.cc[@intFromEnum(posix.V.MIN)] = 0;
    term.cc[@intFromEnum(posix.V.TIME)] = 1;

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, term);
    return orig_term;
}

fn disableRawMode(orig_term: std.posix.termios) void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig_term) catch {
        @panic("Disable raw mode failed!\n");
    };
}

fn editorReadKey() !u8{
    var buf:[1]u8 = undefined;
    const n = try posix.read(posix.STDIN_FILENO, &buf);
    if (n == -1) {
        @panic("die");
    }
    return buf[0];
}

fn editorProcessKeypress() !void {
    const c = try editorReadKey();
    switch (c) {
        ctrl_q => {
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[2J");
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[H");
            posix.exit(0);
            return error.InvalidValue;
            },
        else => {
            if(std.ascii.isControl(c)) {
                try stdout.print("control 0x{x}\r\n", .{c});
            } else {
                try stdout.print("key {c} 0x{x}\r\n", .{c, c});
            }
        },
    }
}

fn editorDrawRows() !void {
    for (0..24) |_|{
        _ = try posix.write(posix.STDOUT_FILENO, "~\r\n");
    }
}

fn editorRefreshScreen() !void {
    _ = try posix.write(posix.STDOUT_FILENO, "\x1b[2J");
    _ = try posix.write(posix.STDOUT_FILENO, "\x1b[H");

    try editorDrawRows();

    _ = try posix.write(posix.STDOUT_FILENO, "\x1b[H");
}

pub fn main() !void {
    const orig_term = try enableRawMode();
    defer {
        stdout.print("disable raw mode\n", .{}) catch {};
        disableRawMode(orig_term);
    }
    // const stdout = std.io.getStdOut().writer();
    // const stdin_fd: posix.fd_t = posix.STDIN_FILENO;

    // var buf: [1]u8 = undefined;

    while (true) {
        try editorRefreshScreen();
        try editorProcessKeypress();
        // const n = try posix.read(stdin_fd, &buf);
        // if (n == 0) break;
        // const b = buf[0];
        // if(std.ascii.isControl(b)) {
        //     try stdout.print("control 0x{x}\r\n", .{b});
        // } else {
        //     try stdout.print("key {c} 0x{x}\r\n", .{b, b});
        // }
        // if (b == ctrl_q or b == 'q') {
        //     try stdout.print("\nquit\n", .{});
        //     break;
        // }
    }
}

const std = @import("std");
const posix = std.posix;
const stdout = std.io.getStdOut().writer();