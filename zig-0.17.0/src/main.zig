//! kilo 的程序入口。
//!
//! 这里负责：
//! - 解析命令行参数；
//! - 初始化 Editor 和终端；
//! - 注册 SIGWINCH（窗口大小变化）回调；
//! - 驱动“刷新屏幕 → 读取并处理按键”的主循环。

const std = @import("std");
const posix = std.posix;
const Editor = @import("Editor.zig");

// SIGWINCH 回调拿不到 Editor 指针，所以用全局变量保存当前编辑器实例。
// 进程内只有一个编辑器，这样写比把指针塞进 signal handler 简单。
var editor: Editor = undefined;

/// 终端窗口大小变化时被内核调用。
///
/// 注意：信号处理函数运行在很受限的上下文里，这里只做最小工作：
/// 重新查询窗口大小并刷新屏幕。严格来说 refreshScreen 不是
/// async-signal-safe 的，但 kilo 原版也是这个思路，实际使用足够。
fn handleSigWinCh(_: std.c.SIG) callconv(.c) void {
    editor.handleResize();
}

pub fn main(init: std.process.Init) !void {
    // Zig 0.17 的带资源注入 main（std.process.Init）会提供 gpa、io 和 arena。
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // 参数只需要活到本次 main 结束，放进 arena 可以省去逐个释放。
    const args = try init.minimal.args.toSlice(arena);
    defer arena.free(args);

    // kilo 只接受一个文件名参数。
    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(io, "Usage: kilo <filename>\n");
        std.process.exit(1);
    }

    // Editor.init 会打开 /dev/tty 并查询窗口大小。
    // 之后的 termios 恢复、fd 关闭都交给 editor.deinit。
    editor = try Editor.init(allocator, io);
    defer editor.deinit();

    // 注册窗口大小变化信号。这里只关心 SIGWINCH，其他信号保持默认行为。
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigWinCh },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(std.c.SIG.WINCH, &sa, null);

    // 打开文件（不存在也没关系，相当于新建文件）。
    try editor.open(args[1]);

    // 进入 raw mode；defer editor.deinit() 会在退出时恢复终端。
    try editor.term.enableRawMode();

    editor.setStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find");

    // 主循环：先画一帧，再阻塞等待一个按键。
    // processKeypress 返回 false 表示用户确认退出。
    while (true) {
        editor.refreshScreen();
        if (!editor.processKeypress()) {
            // 用 return 而不是 process.exit()，让 defer 正常执行，
            // 从而恢复 termios 并关闭 /dev/tty。
            return;
        }
    }
}
