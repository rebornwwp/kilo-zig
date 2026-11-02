//! 单行文本的数据结构。
//!
//! `Row` 保存两类内容：
//! - `chars`：文件的真实内容（制表符仍然是 `\t`）；
//! - `render`：把制表符展开成空格后的显示内容；
//! - `hl`：与 `render` 一一对应的语法高亮类型。
//!
//! 这样保存时可以直接写回 `chars`，渲染时则使用 `render`。

const std = @import("std");
const syntax = @import("syntax.zig");
const Highlight = syntax.Highlight;

/// tab stop 为 8 列：制表符会补齐到下一个 8 的倍数位置。
const tab_stop = 8;

const Self = @This();

/// 当前行在文件中的行号。插入/删除行后需要重新编号。
idx: usize,
/// 原始文本，不带换行符。
chars: std.ArrayList(u8),
/// 展开制表符后的文本，用于屏幕显示。
render: std.ArrayList(u8),
/// 每个显示字符对应的高亮类型。
hl: std.ArrayList(Highlight),
/// 该行结束时是否仍处于多行注释中，供下一行高亮使用。
has_open_comment: bool,
/// 所有 ArrayList 共用的分配器。
allocator: std.mem.Allocator,

/// 创建一行，并复制传入的文本。
pub fn init(allocator: std.mem.Allocator, at: usize, s: []const u8) !Self {
    var row = Self{
        .idx = at,
        .chars = std.ArrayList(u8).empty,
        .render = std.ArrayList(u8).empty,
        .hl = std.ArrayList(Highlight).empty,
        .has_open_comment = false,
        .allocator = allocator,
    };
    try row.chars.appendSlice(allocator, s);
    return row;
}

/// 释放该行持有的所有内存。
pub fn deinit(self: *Self) void {
    self.chars.deinit(self.allocator);
    self.render.deinit(self.allocator);
    self.hl.deinit(self.allocator);
}

/// 根据 `chars` 重新生成 `render`，并触发语法高亮。
///
/// 制表符不是简单替换成一个空格，而是补齐到下一个 8 列边界。
pub fn updateRender(self: *Self, rows: []Self, syn: ?*const syntax.Syntax) void {
    // 先统计制表符数量，估算展开后需要的容量。
    var tabs: usize = 0;
    for (self.chars.items) |ch| {
        if (ch == '\t') tabs += 1;
    }

    self.render.items.len = 0;
    self.render.ensureTotalCapacity(self.allocator, self.chars.items.len + tabs * 7 + 1) catch return;

    var col: usize = 0;
    for (self.chars.items) |ch| {
        if (ch == '\t') {
            // 至少输出一个空格，然后补齐到 tab_stop 的整数倍。
            self.render.append(self.allocator, ' ') catch return;
            col += 1;
            while (col % tab_stop != 0) {
                self.render.append(self.allocator, ' ') catch return;
                col += 1;
            }
        } else {
            self.render.append(self.allocator, ch) catch return;
            col += 1;
        }
    }

    syntax.update(self, rows, syn);
}

/// 在指定列插入一个字符。
///
/// 如果 `at` 超出当前行长度，会先用空格补齐，模拟编辑器里
/// 在行尾之外继续输入的行为。
pub fn insertChar(self: *Self, at: usize, ch: u8) void {
    const size = self.chars.items.len;
    if (at > size) {
        const padlen = at - size;
        self.chars.ensureTotalCapacity(self.allocator, size + padlen + 1) catch return;
        self.chars.appendNTimes(self.allocator, ' ', padlen) catch return;
        self.chars.append(self.allocator, ch) catch return;
    } else {
        self.chars.insert(self.allocator, at, ch) catch return;
    }
}

/// 删除指定列上的字符。
pub fn deleteChar(self: *Self, at: usize) void {
    if (at >= self.chars.items.len) return;
    _ = self.chars.orderedRemove(at);
}

/// 在行尾追加一段文本（删除行时合并到上一行会用到）。
pub fn appendString(self: *Self, s: []const u8) void {
    self.chars.appendSlice(self.allocator, s) catch return;
}

/// 把行截断到指定长度。
pub fn truncate(self: *Self, len: usize) void {
    self.chars.items.len = len;
}
