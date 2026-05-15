const std = @import("std");
const Row = @import("Row.zig");

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

    pub fn color(self: Highlight) u8 {
        return switch (self) {
            .comment, .mlcomment => 36,
            .keyword1 => 33,
            .keyword2 => 32,
            .string => 35,
            .number => 31,
            .match => 34,
            else => 37,
        };
    }
};

pub const HighlightFlags = packed struct {
    strings: bool = false,
    numbers: bool = false,
};

pub const Syntax = struct {
    filematch: []const []const u8,
    keywords: []const []const u8,
    singleline_comment_start: []const u8,
    multiline_comment_start: []const u8,
    multiline_comment_end: []const u8,
    flags: HighlightFlags,

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

const separator_chars = ",.()+-/*=~%[];";

fn isSeparator(ch: u8) bool {
    return ch == 0 or std.ascii.isWhitespace(ch) or
        std.mem.indexOfScalar(u8, separator_chars, ch) != null;
}

pub fn update(row: *Row, rows: []Row, syntax: ?*const Syntax) void {
    const rsize = row.render.items.len;

    row.hl.items.len = 0;
    row.hl.ensureTotalCapacity(row.allocator, rsize) catch return;
    row.hl.items.len = rsize;
    @memset(row.hl.items, .normal);

    const syn = syntax orelse return;

    var i: usize = 0;
    var prev_sep: bool = true;
    var in_string: u8 = 0;
    var in_comment: bool = if (row.idx > 0) hasOpenComment(&rows[row.idx - 1]) else false;

    while (i < rsize) {
        const ch = row.render.items[i];

        if (processMultilineComment(row, syn, &i, &in_comment, &prev_sep)) continue;
        if (processSinglelineComment(row, syn.singleline_comment_start, i, rsize, prev_sep)) break;
        if (processString(row, &i, &in_string, rsize, &prev_sep, syn.flags)) continue;

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

    const oc = hasOpenComment(row);
    if (row.has_open_comment != oc and row.idx + 1 < rows.len) {
        update(&rows[row.idx + 1], rows, syntax);
    }
    row.has_open_comment = oc;
}

fn hasOpenComment(row: *const Row) bool {
    const rsize = row.render.items.len;
    if (rsize == 0 or row.hl.items.len == 0) return false;
    if (row.hl.items[rsize - 1] != .mlcomment) return false;
    if (rsize < 2) return true;
    return !(row.render.items[rsize - 2] == '*' and row.render.items[rsize - 1] == '/');
}

fn processMultilineComment(row: *Row, syn: *const Syntax, i: *usize, in_comment: *bool, prev_sep: *bool) bool {
    const mcs = syn.multiline_comment_start;
    const mce = syn.multiline_comment_end;
    const rsize = row.render.items.len;
    const ch = row.render.items[i.*];

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

fn processSinglelineComment(row: *Row, scs: []const u8, i: usize, rsize: usize, prev_sep: bool) bool {
    if (prev_sep and scs.len >= 2 and i + 1 < rsize and
        row.render.items[i] == scs[0] and row.render.items[i + 1] == scs[1])
    {
        @memset(row.hl.items[i..], .comment);
        return true;
    }
    return false;
}

fn processString(row: *Row, i: *usize, in_string: *u8, rsize: usize, prev_sep: *bool, flags: HighlightFlags) bool {
    if (!flags.strings) return false;

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

// C/C++ syntax database
const c_extensions = [_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".cc" };
const c_keywords = [_][]const u8{
    "auto",             "break",         "case",        "continue",   "default",
    "do",               "else",          "enum",        "extern",     "for",
    "goto",             "if",            "register",    "return",     "sizeof",
    "static",           "struct",        "switch",      "typedef",    "union",
    "volatile",         "while",         "NULL",
    "alignas",          "alignof",       "and",         "and_eq",     "asm",
    "bitand",           "bitor",         "class",       "compl",      "constexpr",
    "const_cast",       "deltype",       "delete",      "dynamic_cast",
    "explicit",         "export",        "false",       "friend",     "inline",
    "mutable",          "namespace",     "new",         "noexcept",   "not",
    "not_eq",           "nullptr",       "operator",    "or",         "or_eq",
    "private",          "protected",     "public",      "reinterpret_cast",
    "static_assert",    "static_cast",   "template",    "this",
    "thread_local",     "throw",         "true",        "try",        "typeid",
    "typename",         "virtual",       "xor",         "xor_eq",
    // Types (suffixed with | for keyword2 coloring)
    "int|",             "long|",         "double|",     "float|",     "char|",
    "unsigned|",        "signed|",       "void|",       "short|",     "auto|",
    "const|",           "bool|",
};

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
