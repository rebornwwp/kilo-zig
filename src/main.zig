const KILO_TAB_STOP = 8;

const Key = enum(u8) {
    ctrl_q = 0x11,
    ctrl_s = 0x13,
    ctrl_d = 0x04,
    ctrl_a = 0x01,
    esc = 0x1b,

    left = 127,
    right,
    up,
    down,
    del,
    home,
    end,
    page_up,
    page_down,
    _,
};

const Row = struct {
    row: std.ArrayList(u8),
    render: std.ArrayList(u8),
};

const EditorConfig = struct {
    allocator: std.mem.Allocator,

    cx: usize,
    cy: usize,
    rx: usize, // render curser的index

    screenrows: usize,
    screencols: usize,

    rowoff: usize,
    coloff: usize,
    numrows: usize,
    rows: std.ArrayList(Row),

    filename: ?[]const u8,

    orig_termios: posix.termios,

    should_quit: bool = false,
};

var E: EditorConfig = undefined;

fn initEditor(allocator: std.mem.Allocator) !void {
    E.allocator = allocator;

    var ws: posix.winsize = undefined;
    try getWindowSize(&ws);
    E.screenrows = ws.row;
    E.screencols = ws.col;
    E.cx = 0;
    E.cy = 0;

    E.rx = 0;

    E.rowoff = 0;
    E.coloff = 0;
    E.rows = std.ArrayList(Row).init(E.allocator);
    E.numrows = 0;
    E.screenrows -= 1;
    E.filename = null;
}

fn deinit() void {
    for (E.rows.items) |*item| {
        std.debug.print("YYYYY: {s}\n", .{item.row.items});
        std.debug.print("XXXXX: {s}\n", .{item.render.items});
        item.row.deinit();
        item.render.deinit();
    }
    E.rows.deinit();
    if (E.filename) |m| {
        E.allocator.free(m);
    }
}

fn editorOpen(filename: ?[]const u8) !void {
    if (filename) |path| {
        E.filename = try E.allocator.dupe(u8, path);
        const file = try std.fs.cwd().openFile(
            path,
            .{ .mode = .read_only },
        );
        defer file.close();

        var reader = std.io.bufferedReader(file.reader());
        const buffer = reader.reader();

        while (try buffer.readUntilDelimiterOrEofAlloc(
            E.allocator,
            '\n',
            std.math.maxInt(usize),
        )) |line| {
            defer E.allocator.free(line);
            var row: Row = .{
                .row = std.ArrayList(u8).init(E.allocator),
                .render = std.ArrayList(u8).init(E.allocator),
            };
            try row.row.appendSlice(line);
            // try E.rows.append(row);
            try editorAppendRow(&row);
        }
    }

    // E.numrows = 1;
    // E.rows = std.ArrayList(std.ArrayList(u8)).init(E.allocator);
    // var row = std.ArrayList(u8).init(E.allocator);
    // try row.appendSlice("this is a line");
    // try E.rows.append(row);
}

fn editorAppendRow(row: *Row) !void {
    try E.rows.append(row.*);
    try editorUpdateRow(row);
    E.numrows += 1;
}

fn editorRowCxToRx(row: *Row, cx: usize) usize {
    var rx: usize = 0;
    for (0..cx) |j| {
        if (row.row.items[j] == '\t') rx += (KILO_TAB_STOP - 1) - (rx % KILO_TAB_STOP);
        rx += 1;
    }
    return rx;
}

fn editorScroll() void {
    E.rx = 0;
    if (E.cy < E.numrows) {
        E.rx = editorRowCxToRx(&E.rows.items[E.cy], E.cx);
    }

    if (E.cy < E.rowoff) {
        E.rowoff = E.cy;
    }

    if (E.cy >= E.rowoff + E.screenrows) {
        E.rowoff = E.cy - E.screenrows + 1;
    }

    if (E.rx < E.coloff) {
        E.coloff = E.rx;
    }

    if (E.rx >= E.coloff + E.screencols) {
        E.coloff = E.rx - E.screencols + 1;
    }
}

fn editorUpdateRow(row: *Row) !void {
    // const render = row.render;
    row.render.deinit();

    // var tabs_count: usize = 0;
    // for (row.row.items) |c| {
    //     if (c == '\t') tabs_count += 1;
    // }
    row.render = std.ArrayList(u8).init(E.allocator);
    try row.render.appendSlice(row.row.items);

    std.debug.print("x1: {s}\n", .{row.row.items});
    std.debug.print("x2: {s}\n", .{row.render.items});
    // render.deinit();
    // try row.render.appendSlice(row.row.items);
    // row.render = try std.ArrayList(u8).initCapacity(
    //     E.allocator,
    //     row.row.items.len + tabs_count * (KILO_TAB_STOP - 1) + 1,
    // );
    // // row.render = std.ArrayList(u8).init(E.allocator);

    // for (row.row.items) |c| {
    //     try row.render.append(c);
    //     // const insert_time: usize = if (c == '\t') KILO_TAB_STOP else 1;
    //     // const insert_c: u8 = if (c == '\t') ' ' else c;
    //     // for (0..insert_time) |_| {
    //     //     try row.render.append(insert_c);
    //     // }
    // }
    // std.debug.print("{s}\r\n", .{row.row.items});
    // try row.render.appendSlice(row.row.items);
    // row.render = try row.row.clone();
    // try row.render.appendSlice(row.row.items);

    // var buf: [80]u8 = undefined;
    // _ = try std.fmt.bufPrint(&buf, "{s}\n", .{row.render.items[0..]});
    // @panic(buf[0..]);
}

fn editorRowInsertChar(row: *Row, at: usize, c: u8) !void {
    const idx = if (at < 0 or at > row.row.items.len)
        row.row.items.len
    else
        at;
    try row.row.insert(idx, c);
    try editorUpdateRow(row);
}

fn editorInsertChar(c: u8) !void {
    if (E.cy == E.numrows) {
        var row: Row = .{
            .row = std.ArrayList(u8).init(E.allocator),
            .render = std.ArrayList(u8).init(E.allocator),
        };
        try editorAppendRow(&row);
    }
    try editorRowInsertChar(&E.rows.items[E.cy], E.cx, c);
    E.cx += 1;
}

// fn editorRowsToString(int buflen) {

// }

fn enableRawMode() !void {
    const orig_term = try posix.tcgetattr(posix.STDIN_FILENO);
    E.orig_termios = orig_term;
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

    // try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, term);
}

fn disableRawMode() void {
    // posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, E.orig_termios) catch {
    //     @panic("Disable raw mode failed!\n");
    // };
}

fn isDigit(c: u8) bool {
    switch (c) {
        '0'...'9' => return true,
        else => return false,
    }
}

fn editorReadKey() !Key {
    var buf: [1]u8 = undefined;
    const n = try posix.read(posix.STDIN_FILENO, &buf);
    if (n == -1) {
        @panic("die");
    }
    const k: Key = @enumFromInt(buf[0]);
    if (k == .esc) {
        var seq: [3]u8 = undefined;
        const nread = try posix.read(posix.STDIN_FILENO, &seq);
        if (seq[0] == '[') {
            if (nread == 3 and isDigit(seq[1])) {
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '1' => return .home,
                        '3' => return .del,
                        '4' => return .end,
                        '5' => return .page_up,
                        '6' => return .page_down,
                        '7' => return .home,
                        '8' => return .end,
                        else => {},
                    }
                }
            }
            switch (seq[1]) {
                'A' => return .up, // up
                'B' => return .down, // down
                'C' => return .right, // right
                'D' => return .left, // left
                'H' => return .home,
                'F' => return .end,
                else => {},
            }
        } else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return .home,
                'F' => return .end,
                else => {},
            }
        }
    }
    return k;
}

fn editorProcessKeypress() !void {
    const k = try editorReadKey();
    switch (k) {
        Key.ctrl_q => {
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[2J");
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[H");
            E.should_quit = true;
            // posix.exit(0);
            // return error.InvalidValue;
        },
        Key.up, Key.down, Key.left, Key.right => {
            try editorMoveCursor(k);
        },
        else => {
            const c = @intFromEnum(k);
            if (std.ascii.isPrint(c) and !std.ascii.isControl(c)) try editorInsertChar(c);
        },
    }
}

fn editorDrawRows(abuf: *std.ArrayList(u8)) !void {
    for (0..E.screenrows) |i| {
        const filerow = i + E.rowoff;
        if (filerow >= E.numrows) {
            if (E.numrows == 0 and i == E.screenrows / 3) {
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
            // try abuf.appendSlice("\x1b[K");
            // if (i < E.screenrows - 1) {
            //     try abuf.appendSlice("\r\n");
            // }
        } else {
            var len = E.rows.items[filerow].render.items.len - E.coloff;
            if (len < 0) len = 0;
            if (len > E.screencols) len = E.screencols;
            try abuf.appendSlice(E.rows.items[filerow].render.items[E.coloff..]);
        }
        try abuf.appendSlice("\x1b[K");
        // if (i < E.screenrows - 1) {
        try abuf.appendSlice("\r\n");
        // }
    }
}

fn editorDrawStatusBar(abuf: *std.ArrayList(u8)) !void {
    try abuf.appendSlice("\x1b[7m");
    var status: [80]u8 = undefined;
    const filename = if (E.filename) |path|
        path
    else
        "[No Name]";
    var result = try std.fmt.bufPrint(&status, "{s} - {d} lines", .{ filename, E.numrows });
    // const len = if (status.len > E.screencols) E.screencols else status.len;
    try abuf.appendSlice(result[0..result.len]);
    for (result.len..E.screencols) |_| {
        try abuf.append(' ');
    }
    try abuf.appendSlice("\x1b[m");
}

fn editorRefreshScreen() !void {
    editorScroll();
    var abuf = std.ArrayList(u8).init(E.allocator);
    defer abuf.deinit();

    try abuf.appendSlice("\x1b[?25l");
    // try abuf.appendSlice("\x1b[2J");
    try abuf.appendSlice("\x1b[H");
    try editorDrawRows(&abuf);
    try editorDrawStatusBar(&abuf);

    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(
        &buf,
        "\x1b[{d};{d}H",
        .{
            E.cy - E.rowoff + 1,
            E.rx - E.coloff + 1,
        },
    );
    try abuf.appendSlice(str);

    // try abuf.appendSlice("\x1b[H");
    try abuf.appendSlice("\x1b[?25h");
    _ = try posix.write(posix.STDOUT_FILENO, abuf.items);
}

fn editorMoveCursor(key: Key) !void {
    const row = if (E.cy >= E.numrows) null else E.rows.items[E.cy];
    switch (key) {
        Key.left => {
            if (E.cx > 0) {
                E.cx -= 1;
            } else if (E.cy > 0) {
                // 切换到上一行的行尾
                E.cy -= 1;
                E.cx = E.rows.items[E.cy].row.items.len;
            }
        },
        Key.right => {
            // if (E.cx <= E.screencols - 1)
            if (row) |r| {
                if (E.cx < r.row.items.len) {
                    E.cx += 1;
                } else if (E.cx == r.row.items.len) {
                    // 切换到下一行的行头
                    E.cy += 1;
                    E.cx = 0;
                }
            }
            // if (row) |r| {
            //     if (E.cx < r.items.len) {
            //         E.cx += 1;
            //     }
            // }
        },
        Key.up => {
            if (E.cy > 0) E.cy -= 1;
        },
        Key.down => {
            if (E.cy < E.numrows) E.cy += 1;
        },
        else => return error.InvalidValue,
    }

    const ro = if (E.cy >= E.numrows) null else E.rows.items[E.cy];
    if (ro) |r| {
        if (E.cx > r.row.items.len) E.cx = r.row.items.len;
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try enableRawMode();
    defer disableRawMode();
    try initEditor(allocator);
    defer deinit();

    var args = std.process.args();
    _ = args.next(); // ignore first arg

    try editorOpen(args.next());

    // // const stdout = std.io.getStdOut().writer();
    // // const stdin_fd: posix.fd_t = posix.STDIN_FILENO;

    // // var buf: [1]u8 = undefined;

    // // for (E.rows.items) |row| {
    // //     std.debug.print("xxxxxxxxx: {s}\n", .{row.items});
    // // }

    // try editorRefreshScreen();
    // try editorProcessKeypress();
    return;

    // while (E.should_quit == false) {
    //     try editorRefreshScreen();
    //     try editorProcessKeypress();
    //     // const n = try posix.read(stdin_fd, &buf);
    //     // if (n == 0) break;
    //     // const b = buf[0];
    //     // if(std.ascii.isControl(b)) {
    //     //     try stdout.print("control 0x{x}\r\n", .{b});
    //     // } else {
    //     //     try stdout.print("key {c} 0x{x}\r\n", .{b, b});
    //     // }
    //     // if (b == ctrl_q or b == 'q') {
    //     //     try stdout.print("\nquit\n", .{});
    //     //     break;
    //     // }
    // }
}

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const stdout = std.io.getStdOut().writer();
