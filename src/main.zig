fn enableRawMode() !std.posix.termios {
    const orig_term = try posix.tcgetattr(posix.STDIN_FILENO);
    var term = orig_term;

    term.lflag.ICANON = false;
    term.lflag.ECHO = false;
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, term);
    return orig_term;
}

fn disableRawMode(orig_term: std.posix.termios) void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig_term) catch {
        @panic("Disable raw mode failed!\n");
    };
}

pub fn main() !void {
    const orig_term = try enableRawMode();
    defer {
        disableRawMode(orig_term);
    }
    const stdout = std.io.getStdOut().writer();
    const stdin_fd: posix.fd_t = posix.STDIN_FILENO;

    var buf: [1]u8 = undefined;

    while (true) {
        const n = try posix.read(stdin_fd, &buf);
        if (n == 0) break;
        const b = buf[0];
        if (b == 0x11 or b == 'q') {
            stdout.print("\nquit\n", .{}) catch |err| {
                return err;
            };
            break;
        }
        if (b >= 32 and b < 127) {
            try stdout.print("key : '{c}' (0x{x})\n", .{ b, b });
        } else {
            try stdout.print("key : 0x{x}\n", .{b});
        }
    }
}

const std = @import("std");
const posix = std.posix;
