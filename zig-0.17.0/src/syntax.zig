//! 极简语法高亮器。
//!
//! 实现方式接近 kilo 原版：对每一行的显示文本 `render` 逐字符扫描，
//! 给每个字符打上 `Highlight` 标记。主要支持：
//! - 单行注释 `//`
//! - 多行注释 `/* ... */`
//! - 字符串（单引号/双引号）
//! - 数字
//! - 关键字（普通关键字和类型关键字）
//!
//! 多行注释会跨行传播：当前行结束时如果还在注释里，下一行会从注释状态开始。

const std = @import("std");
const Row = @import("Row.zig");

/// 一个显示字符的高亮类型。
pub const Highlight = enum(u8) {
    normal,
    nonprint,
    comment,
    mlcomment,
    keyword1,
    keyword2,
    string,
    number,
    match,

    /// 返回对应的 ANSI 前景色编号。
    pub fn color(self: Highlight) u8 {
        return switch (self) {
            .comment, .mlcomment => 36, // 青色
            .keyword1 => 33, // 黄色
            .keyword2 => 32, // 绿色
            .string => 35, // 洋红
            .number => 31, // 红色
            .match => 34, // 蓝色
            else => 37, // 白色
        };
    }
};

/// 某种语言支持哪些高亮能力。
pub const HighlightFlags = packed struct {
    strings: bool = false,
    numbers: bool = false,
};

/// 一门语言的语法配置。
pub const Syntax = struct {
    /// 文件名匹配模式，例如 `.c`、`.h`。只要文件名包含即可。
    filematch: []const []const u8,
    /// 关键字列表。以 `|` 结尾的条目表示“类型关键字”，用不同颜色显示。
    keywords: []const []const u8,
    /// 单行注释起始符，例如 `//`。
    singleline_comment_start: []const u8,
    /// 多行注释起始符，例如 `/*`。
    multiline_comment_start: []const u8,
    /// 多行注释结束符，例如 `*/`。
    multiline_comment_end: []const u8,
    /// 是否启用字符串/数字高亮。
    flags: HighlightFlags,

    /// 根据文件名选择语法配置。
    ///
    /// 匹配规则保持 kilo 原版行为：
    /// - 文件名包含扩展名即可；
    /// - 但如果模式以 `.` 开头，则要求它第一次出现的位置刚好在
    ///   文件名末尾，避免 `foo.c.bak` 被误判成 C 文件。
    pub fn detect(filename: []const u8) ?*const Syntax {
        for (&hldb) |*s| {
            for (s.filematch) |pat| {
                if (std.mem.indexOf(u8, filename, pat)) |pos| {
                    if (pat[0] != '.' or pos + pat.len == filename.len) {
                        return s;
                    }
                }
            }
        }
        return null;
    }
};

/// 关键字边界字符。关键字前后必须是空白、字符串结束或这些符号之一。
const separator_chars = ",.()+-/*=~%[];";

fn isSeparator(ch: u8) bool {
    return ch == 0 or std.ascii.isWhitespace(ch) or
        std.mem.indexOfScalar(u8, separator_chars, ch) != null;
}

/// 为一行生成高亮信息。
///
/// `rows` 用于判断上一行是否还处于多行注释中；如果当前行的注释状态
/// 发生变化，会递归更新下一行。
pub fn update(row: *Row, rows: []Row, syntax: ?*const Syntax) void {
    const rsize = row.render.items.len;

    // 先把整行标记为 normal，之后扫描时覆盖。
    row.hl.items.len = 0;
    row.hl.ensureTotalCapacity(row.allocator, rsize) catch return;
    row.hl.items.len = rsize;
    @memset(row.hl.items, .normal);

    const syn = syntax orelse return;

    var i: usize = 0;
    var prev_sep: bool = true;
    var in_string: u8 = 0;
    // 当前行是否从上一行继承“多行注释未结束”的状态。
    var in_comment: bool = if (row.idx > 0) hasOpenComment(&rows[row.idx - 1]) else false;

    while (i < rsize) {
        const ch = row.render.items[i];

        // 每个处理函数如果消费了字符，就返回 true，主循环直接进入下一轮。
        if (processMultilineComment(row, syn, &i, &in_comment, &prev_sep)) continue;
        if (processSinglelineComment(row, syn.singleline_comment_start, i, rsize, prev_sep)) break;
        if (processString(row, &i, &in_string, rsize, &prev_sep, syn.flags)) continue;

        // 控制字符等不可打印字符用反色显示。
        if (!std.ascii.isPrint(ch)) {
            row.hl.items[i] = .nonprint;
            i += 1;
            prev_sep = false;
            continue;
        }

        if (processNumber(row, syn.flags, &i, prev_sep)) {
            prev_sep = false;
            continue;
        }
        if (processKeyword(row, syn.keywords, &i, rsize, &prev_sep)) continue;

        prev_sep = isSeparator(ch);
        i += 1;
    }

    // 如果本行的注释状态影响下一行，递归刷新下一行。
    const oc = hasOpenComment(row);
    if (row.has_open_comment != oc and row.idx + 1 < rows.len) {
        update(&rows[row.idx + 1], rows, syntax);
    }
    row.has_open_comment = oc;
}

/// 判断这一行结束时是否仍处于多行注释中。
fn hasOpenComment(row: *const Row) bool {
    const rsize = row.render.items.len;
    if (rsize == 0 or row.hl.items.len == 0) return false;
    if (row.hl.items[rsize - 1] != .mlcomment) return false;
    if (rsize < 2) return true;
    // 行尾是 `*/` 说明注释已经闭合。
    return !(row.render.items[rsize - 2] == '*' and row.render.items[rsize - 1] == '/');
}

/// 处理多行注释的开始、结束和注释内容。
fn processMultilineComment(row: *Row, syn: *const Syntax, i: *usize, in_comment: *bool, prev_sep: *bool) bool {
    const mcs = syn.multiline_comment_start;
    const mce = syn.multiline_comment_end;
    const rsize = row.render.items.len;
    const ch = row.render.items[i.*];

    // 已经处于注释中：一直标记，直到遇到结束符。
    if (in_comment.*) {
        row.hl.items[i.*] = .mlcomment;
        if (mce.len >= 2 and i.* + 1 < rsize and ch == mce[0] and row.render.items[i.* + 1] == mce[1]) {
            row.hl.items[i.* + 1] = .mlcomment;
            i.* += 2;
            in_comment.* = false;
            prev_sep.* = true;
        } else {
            prev_sep.* = false;
            i.* += 1;
        }
        return true;
    }

    // 不在注释中：检查是否出现多行注释起始符。
    if (mcs.len >= 2 and i.* + 1 < rsize and ch == mcs[0] and row.render.items[i.* + 1] == mcs[1]) {
        row.hl.items[i.*] = .mlcomment;
        row.hl.items[i.* + 1] = .mlcomment;
        i.* += 2;
        in_comment.* = true;
        prev_sep.* = false;
        return true;
    }
    return false;
}

/// 处理单行注释：从 `//` 开始到行尾全部标成注释。
fn processSinglelineComment(row: *Row, scs: []const u8, i: usize, rsize: usize, prev_sep: bool) bool {
    if (prev_sep and scs.len >= 2 and i + 1 < rsize and
        row.render.items[i] == scs[0] and row.render.items[i + 1] == scs[1])
    {
        @memset(row.hl.items[i..], .comment);
        return true;
    }
    return false;
}

/// 处理字符串，包括反斜杠转义。
fn processString(row: *Row, i: *usize, in_string: *u8, rsize: usize, prev_sep: *bool, flags: HighlightFlags) bool {
    if (!flags.strings) return false;

    // 已经在字符串中：继续标记，直到遇到同种引号。
    if (in_string.* != 0) {
        row.hl.items[i.*] = .string;
        if (row.render.items[i.*] == '\\' and i.* + 1 < rsize) {
            row.hl.items[i.* + 1] = .string;
            i.* += 2;
            prev_sep.* = false;
            return true;
        }
        if (row.render.items[i.*] == in_string.*) in_string.* = 0;
        i.* += 1;
        prev_sep.* = false;
        return true;
    }

    // 字符串开始。
    const ch = row.render.items[i.*];
    if (ch == '"' or ch == '\'') {
        in_string.* = ch;
        row.hl.items[i.*] = .string;
        i.* += 1;
        prev_sep.* = false;
        return true;
    }
    return false;
}

/// 处理数字，包括小数点和连续数字。
fn processNumber(row: *Row, flags: HighlightFlags, i: *usize, prev_sep: bool) bool {
    if (!flags.numbers) return false;

    const ch = row.render.items[i.*];
    if ((std.ascii.isDigit(ch) and (prev_sep or (i.* > 0 and row.hl.items[i.* - 1] == .number))) or
        (ch == '.' and i.* > 0 and row.hl.items[i.* - 1] == .number))
    {
        row.hl.items[i.*] = .number;
        i.* += 1;
        return true;
    }
    return false;
}

/// 处理关键字。
///
/// 关键字必须以分隔符为边界；以 `|` 结尾的条目表示类型关键字，
/// 使用 `.keyword2` 颜色。
fn processKeyword(row: *Row, keywords: []const []const u8, i: *usize, rsize: usize, prev_sep: *bool) bool {
    if (!prev_sep.*) return false;

    for (keywords) |kw| {
        var klen = kw.len;
        const is_type = klen > 0 and kw[klen - 1] == '|';
        if (is_type) klen -= 1;

        if (i.* + klen <= rsize and
            std.mem.eql(u8, row.render.items[i.* .. i.* + klen], kw[0..klen]) and
            (i.* + klen >= rsize or isSeparator(row.render.items[i.* + klen])))
        {
            const hl_type: Highlight = if (is_type) .keyword2 else .keyword1;
            @memset(row.hl.items[i.* .. i.* + klen], hl_type);
            i.* += klen;
            prev_sep.* = false;
            return true;
        }
    }
    return false;
}

// C/C++ 的文件扩展名。
const c_extensions = [_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".cc" };
// 类型关键字以 `|` 结尾，用 keyword2 颜色显示。
// 注意：注释必须放在数组字面量外面，否则 zig fmt 会打乱排版。
const c_keywords = [_][]const u8{
    "auto",             "break",         "case",        "continue",   "default",
    "do",               "else",          "enum",        "extern",     "for",
    "goto",             "if",            "register",    "return",     "sizeof",
    "static",           "struct",        "switch",      "typedef",    "union",
    "volatile",         "while",         "NULL",        "alignas",    "alignof",
    "and",              "and_eq",        "asm",         "bitand",     "bitor",
    "class",            "compl",         "constexpr",   "const_cast", "deltype",
    "delete",           "dynamic_cast",  "explicit",    "export",     "false",
    "friend",           "inline",        "mutable",     "namespace",  "new",
    "noexcept",         "not",           "not_eq",      "nullptr",    "operator",
    "or",               "or_eq",         "private",     "protected",  "public",
    "reinterpret_cast", "static_assert", "static_cast", "template",   "this",
    "thread_local",     "throw",         "true",        "try",        "typeid",
    "typename",         "virtual",       "xor",         "xor_eq",     "int|",
    "long|",            "double|",       "float|",      "char|",      "unsigned|",
    "signed|",          "void|",         "short|",      "auto|",      "const|",
    "bool|",
};

/// 内置语法数据库。当前只包含 C/C++，后续可以继续追加。
pub const hldb = [_]Syntax{
    .{
        .filematch = &c_extensions,
        .keywords = &c_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = .{ .strings = true, .numbers = true },
    },
};
