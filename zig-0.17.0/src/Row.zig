const std = @import("std");
const syntax = @import("syntax.zig");
const Highlight = syntax.Highlight;

const tab_stop = 8;

const Self = @This();

idx: usize,
chars: std.ArrayList(u8),
render: std.ArrayList(u8),
hl: std.ArrayList(Highlight),
has_open_comment: bool,
allocator: std.mem.Allocator,

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

pub fn deinit(self: *Self) void {
    self.chars.deinit(self.allocator);
    self.render.deinit(self.allocator);
    self.hl.deinit(self.allocator);
}

pub fn updateRender(self: *Self, rows: []Self, syn: ?*const syntax.Syntax) void {
    var tabs: usize = 0;
    for (self.chars.items) |ch| {
        if (ch == '\t') tabs += 1;
    }

    self.render.items.len = 0;
    self.render.ensureTotalCapacity(self.allocator, self.chars.items.len + tabs * 7 + 1) catch return;

    var col: usize = 0;
    for (self.chars.items) |ch| {
        if (ch == '\t') {
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

pub fn deleteChar(self: *Self, at: usize) void {
    if (at >= self.chars.items.len) return;
    _ = self.chars.orderedRemove(at);
}

pub fn appendString(self: *Self, s: []const u8) void {
    self.chars.appendSlice(self.allocator, s) catch return;
}

pub fn truncate(self: *Self, len: usize) void {
    self.chars.items.len = len;
}
