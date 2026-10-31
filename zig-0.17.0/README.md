# kilo (Zig 0.17.0)

基于 [`zig-0.16.0-refactor`](../zig-0.16.0-refactor) 迁移而来的 [kilo](https://viewsourcecode.org/snaptoken/kilo/index.html) 文本编辑器 Zig 移植版。

本目录用于记录并验证从 **Zig 0.16.x** 到 **Zig 0.17.0** 的迁移。原目录 `zig-0.16.0-refactor/` 保持原样，未被修改。

## 目录结构

```
zig-0.17.0/
├── build.zig        # 构建脚本（已迁移）
└── src/
    ├── main.zig     # 入口、SIGWINCH、主循环
    ├── Editor.zig   # 编辑器核心：编辑、光标、文件 I/O、查找、渲染
    ├── Row.zig      # 行数据结构与渲染缓存
    ├── terminal.zig # 原始模式、按键解析、窗口大小
    └── syntax.zig   # 语法高亮
```

## 构建与运行

依赖：Zig 0.17.0。

```bash
zig build                 # Debug 构建，产物在 zig-out/bin/kilo
zig build -Doptimize=ReleaseSafe
zig build run -- <filename>
```

按键：

| 按键 | 功能 |
| --- | --- |
| `Ctrl-S` | 保存 |
| `Ctrl-Q` | 退出（有未保存修改时需连续按 3 次） |
| `Ctrl-F` | 查找（`ESC` 退出，方向键切换匹配项） |

---

## 迁移改动详解

本次迁移分为三类：**构建系统 API**、**枚举/整数转换内置函数**、**代码格式化**。

### 1. `build.zig`：`b.args` 被移除

Zig 0.17.0 中 `std.Build` 不再提供 `args` 字段，运行步骤改用 `addPassthruArgs()`。

**改动前（0.16.x）：**

```zig
if (b.args) |args| {
    run_cmd.addArgs(args);
}
```

**改动后（0.17.0）：**

```zig
run_cmd.addPassthruArgs();
```

**原因：**

- 0.17 的 `zig build` 被拆分为 **Configurer**（求值 `build.zig` 生成构建图）和 **Maker**（执行构建）两个阶段。
- 在 `build.zig` 里直接读取 `b.args` 会让命令行参数参与配置缓存的计算，导致每次执行 `zig build run -- foo` 时配置缓存失效。
- `addPassthruArgs()` 把参数透传推迟到执行阶段，使配置缓存保持纯净（configure cache 不会被“污染”）。

### 2. `src/terminal.zig`：枚举转换内置函数更名

Zig 0.17.0 用 `@backingInt` / `@fromBackingInt` 取代 `@intFromEnum` / `@enumFromInt`，`zig fmt` 会自动完成这一步。

**改动前（0.16.x）：**

```zig
pub fn isPrintable(self: Key) bool {
    const k = @intFromEnum(self);
    return k < 128 and std.ascii.isPrint(@as(u8, @truncate(k)));
}

pub fn toChar(self: Key) u8 {
    return @truncate(@intFromEnum(self));
}

// 读取普通按键
if (buf[0] != 27) return @enumFromInt(buf[0]);
```

**改动后（0.17.0）：**

```zig
pub fn isPrintable(self: Key) bool {
    const k = @backingInt(self);
    return k < 128 and std.ascii.isPrint(@as(u8, @truncate(k)));
}

pub fn toChar(self: Key) u8 {
    return @truncate(@backingInt(self));
}

// 读取普通按键
if (buf[0] != 27) return @fromBackingInt(@intCast(buf[0]));
```

**说明：**

- `Key` 的底层类型是 `enum(u16)`，而 `buf[0]` 是 `u8`，因此 `@fromBackingInt` 前需要一次 `@intCast` 把 `u8` 扩宽为 `u16`。
- `@fromBackingInt` 的目标类型由上下文推断（这里是 `Key`），并且会对非法枚举值做安全检查。
- `@backingInt` 除了枚举，也支持有显式底层整数的 `packed struct`/`packed union` 以及 tagged union。

### 3. `src/syntax.zig`：`zig fmt` 排版差异

Zig 0.17.0 的 `zig fmt` 对「数组字面量内部夹注释」的排版行为发生了变化：原本整齐的关键字表被重排，并且 `"int|"` 被错误缩进为单独一行：

```zig
    "typename",         "virtual",       "xor",         "xor_eq",
    // Types (suffixed with | for keyword2 coloring)
        "int|",
    "long|",            "double|",       "float|",      "char|",      "unsigned|",
```

为了让格式稳定且易读，把注释移到数组定义上方，并让数组元素重新按每行 5 个对齐。

**改动：**

```zig
// C/C++ syntax database
const c_extensions = [_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".cc" };
// Types are suffixed with `|` so they are colored as keyword2.
const c_keywords = [_][]const u8{
    "auto",             "break",         "case",        "continue",   "default",
    // ...
    "int|",             "long|",         "double|",     "float|",     "char|",
    "unsigned|",        "signed|",       "void|",       "short|",     "auto|",
    "const|",           "bool|",
};
```

关键字列表内容与原文件逐项一致，仅调整了注释位置和换行/对齐。

### 4. 未改动但仍需说明的部分

`zig-0.16.0-refactor` 的代码大部分已经是 0.17 风格，因此下面这些在 0.17.0 中无需修改：

| 代码 | 说明 |
| --- | --- |
| `std.ArrayList(T).empty` + `list.append(allocator, ...)` | 0.16 起已是显式分配器风格，0.17 保持 |
| `list.last()` / `list.items.len = n` | 未使用已废弃的 `getLastOrNull()` / `getLast()` |
| `std.process.Init` / `std.Io` / `std.Io.File.stderr()` | 已是 0.16+ 的 `std.Io` 接口 |
| `std.Io.Dir.cwd().readFileAlloc(...)` / `createFile(...)` | 签名在 0.17 中保持兼容 |
| `std.heap` 分配器 | 项目未使用 `DebugAllocator` / `StackFallbackAllocator`，无迁移点 |
| `std.fmt.bufPrint` | 只做栈上格式化，未使用已迁移到 `Allocator` 的 `allocPrint` |
| `posix.sigaction`、`std.c.ioctl`、`posix.tcgetattr` 等 | 0.17 中仍可用 |

也就是说，真正影响编译的破坏性变更只有 `build.zig` 的 `b.args`；其余为自动迁移和格式化。

---

## 验证结果

在 Zig **0.17.0** 下执行：

```text
zig build                              ✅
zig build -Doptimize=ReleaseSafe       ✅
zig fmt --check .                      ✅
```

运行时验证（使用伪终端提供 24×80 窗口）：

- 能正常进入原始模式并渲染文件内容；
- 正确显示 `hello` / `world` 两行测试文本；
- 按下 `Ctrl-Q` 后正常退出，退出码为 `0`。

## 与上游的关系

- 项目来源与教程：<https://viewsourcecode.org/snaptoken/kilo/index.html>
- 原始 kilo 作者：Salvatore Sanfilippo（antirez），BSD 2-Clause。
- 本目录仅做 Zig 0.17.0 迁移，不改变编辑器的功能与行为。
