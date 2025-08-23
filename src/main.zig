const Key = enum(u8) {
    ctrl_q = 0x11,
    ctrl_s = 0x13,
    ctrl_d = 0x04,
    ctrl_a = 0x01,
    up = 'w',
    down = 's',
    left = 'a',
    right = 'd',
    pageUp,
    pageDown,
};

const EditorConfig = struct {
    cx: u16,
    cy: u16,

    screenrows: u16,
    screencols: u16,

    numrows: u16,
    row: std.ArrayList(u8),

    orig_termios: posix.termios,
};

var E: EditorConfig = undefined;

fn initEditor() !void {
    var ws: posix.winsize = undefined;
    try getWindowSize(&ws);
    E.screenrows = ws.row;
    E.screencols = ws.col;
    E.cx = 0;
    E.cy = 0;
    E.numrows = 0;
}

fn enableRawMode() !void {
    const orig_term = try posix.tcgetattr(posix.STDIN_FILENO);
    E.orig_termios = orig_term;
    var term = E.orig_termios;

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
}

fn disableRawMode() void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, E.orig_termios) catch {
        @panic("Disable raw mode failed!\n");
    };
}

fn editorReadKey() !u8 {
    var buf: [1]u8 = undefined;
    const n = try posix.read(posix.STDIN_FILENO, &buf);
    if (n == -1) {
        @panic("die");
    }
    if (buf[0] == '\x1b') {
        var seq: [3]u8 = undefined;
        _ = try posix.read(posix.STDIN_FILENO, &seq);
        if (seq[0] == '[') {
            switch (seq[1]) {
                'A' => return @intFromEnum(Key.up), // up
                'B' => return @intFromEnum(Key.down), // down
                'C' => return @intFromEnum(Key.right), // right
                'D' => return @intFromEnum(Key.left), // left
                else => return buf[0],
            }
        }
    }
    return buf[0];
}

fn editorProcessKeypress() !void {
    const c = try editorReadKey();
    switch (c) {
        @intFromEnum(Key.ctrl_q),
        => {
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[2J");
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[H");
            posix.exit(0);
            return error.InvalidValue;
        },
        @intFromEnum(Key.up),
        @intFromEnum(Key.down),
        @intFromEnum(Key.left),
        @intFromEnum(Key.right),
        => {
            try editorMoveCursor(c);
        },
        else => {
            if (std.ascii.isControl(c)) {
                try stdout.print("control 0x{x}\r\n", .{c});
            } else {
                try stdout.print("key {c} 0x{x}\r\n", .{ c, c });
            }
        },
    }
}

fn editorDrawRows(abuf: *std.ArrayList(u8)) !void {
    for (0..E.screenrows) |i| {
        if (i == E.screenrows / 3) {
            // const welcome: [28]u8 =
            // if (28 > E.screencols)
            const wellen = 28;
            var padding = (E.screencols - wellen) / 2;
            if (padding > 0) {
                try abuf.append('~');
                padding -= 1;
            }
            while (padding > 0) {
                try abuf.append(' ');
                padding -= 1;
            }
            try abuf.appendSlice("Kilo editor -- version 0.0.1");
        } else {
            try abuf.append('~');
        }
        try abuf.appendSlice("\x1b[K");
        if (i < E.screenrows - 1) {
            try abuf.appendSlice("\r\n");
        }
    }
}

fn editorRefreshScreen() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var abuf = std.ArrayList(u8).init(allocator);
    defer abuf.deinit();

    try abuf.appendSlice("\x1b[?25l");
    // try abuf.appendSlice("\x1b[2J");
    try abuf.appendSlice("\x1b[H");
    try editorDrawRows(&abuf);

    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ E.cx + 1, E.cy + 1 });
    try abuf.appendSlice(str);

    try abuf.appendSlice("\x1b[H");
    try abuf.appendSlice("\x1b[?25h");
    _ = try posix.write(posix.STDOUT_FILENO, abuf.items);
}

fn editorMoveCursor(key: u8) !void {
    switch (key) {
        @intFromEnum(Key.left) => {
            if (E.cx > 0) E.cx -= 1;
        },
        @intFromEnum(Key.right) => {
            if (E.cx <= E.screencols - 1) E.cx += 1;
        },
        @intFromEnum(Key.up) => {
            if (E.cy > 0) E.cy -= 1;
        },
        @intFromEnum(Key.down) => {
            if (E.cy < E.screenrows - 1) E.cy += 1;
        },
        else => return error.InvalidValue,
    }
}

fn getCursorPosition() !void {
    const x = try posix.write(posix.STDOUT_FILENO, "\x1b[6n");
    if (x != 4) {
        return error.InvalidValue;
    }

    // stdout.print("\r\n", .{});
    var buf: [32]u8 = undefined;
    var i = 0;
    while (i < buf.len - 1) {
        const l = try posix.read(posix.STDOUT_FILENO, &buf[i]);
        if (l != 1) break;
        if (buf[i] == 'R') break;
        i += 1;
    }

    buf[i] = 0;
    if (buf[0] != '\x1b' or buf[1] != '[') {
        return error.InvalidValue;
    }

    try stdout.print("\r\n&buf[1]: '{c}'\r\n", .{buf[1]});
    try posix.write(posix.STDOUT_FILENO, "buf size is:");

    // if (std.ascii.isControl(buf[0])) {
    //     stdout.print("%d\r\n", .{buf[0]});
    // } else {
    //     stdout.print("%d ('%c')\r\n", .{ buf[0], buf[0] });
    // }
    // try editorReadKey();
}

fn getWindowSize(ws: *posix.winsize) !void {
    const result = linux.ioctl(posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(ws));
    if (result == -1) {
        const x = try posix.write(posix.STDOUT_FILENO, "\x1b[999C\x1b[999B");
        if (x != 12) {
            return error.InvalidValue;
        }
        try getCursorPosition();
        _ = try editorReadKey();

        return error.InvalidValue;
    }
}

pub fn main() !void {
    try enableRawMode();
    try initEditor();
    defer {
        stdout.print("disable raw mode\n", .{}) catch {};
        disableRawMode();
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
const linux = std.os.linux;
const stdout = std.io.getStdOut().writer();
