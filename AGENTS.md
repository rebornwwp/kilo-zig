# AGENTS.md

## What this repo is

Side-by-side ports of the [kilo](https://viewsourcecode.org/snaptoken/kilo/index.html) editor, one snapshot per Zig version. There is **no root `build.zig`** — every directory is an independent project. Always `cd` into a version directory before running `zig build`.

| Directory | What it is | Builds on Zig 0.17? |
| --- | --- | --- |
| `kilo/` | Original C implementation, for reference only | n/a |
| `kilo-zig/` | Early/incomplete monolithic port started from the `zig init` template | No |
| `zig-0.15.2/` | Monolithic single-file port, 0.15 APIs | No |
| `zig-0.16.0/` | Monolithic single-file port, 0.16 APIs | No |
| `zig-0.16.0-refactor/` | Split-module port (`Editor`, `Row`, `terminal`, `syntax`) | No |
| `zig-0.17.0/` | Current migration target; copy of the refactor port on 0.17 | Yes |

`zig-0.17.0/` is the only directory that compiles with the installed Zig 0.17.0. Treat the older directories as frozen reference snapshots: do not migrate or fix them unless explicitly asked.

## Commands

```bash
cd zig-0.17.0
zig build                              # Debug, output at zig-out/bin/kilo
zig build -Doptimize=ReleaseSafe
zig build run -- <filename>
zig fmt --check .                      # there is no test/lint step
```

The editor directories have **no test step** and no test blocks. `zig build test` only exists in `kilo-zig/`, whose scaffold test is broken on 0.17; don't use it as verification.

## Runtime gotchas

- The editor links libc (`link_libc = true`) for `std.c.isatty`, `ioctl`, `gettimeofday`.
- It requires a real TTY. A plain non-interactive `zig build run` fails with `error.NotATty`.
- If the terminal reports a zero window size, `Terminal.getWindowSize` falls back to sending `ESC[6n` and **blocks** waiting for a cursor-position reply. Automated smoke tests must run under a pty with `TIOCSWINSZ` set (see the validation notes in `zig-0.17.0/README.md`); otherwise the process appears hung.
- Keys: `Ctrl-S` save, `Ctrl-Q` quit (3 presses when dirty), `Ctrl-F` find.

## Zig 0.17 migration rules (for `zig-0.17.0/`)

Follow `.opencode/skills/zig-0-17/SKILL.md`. The `.qoder/` skills and agent cover only 0.15/0.16 and are stale for this directory.

- In `build.zig`, `b.args` no longer exists. Use `run_cmd.addPassthruArgs()`.
- Use `@backingInt` / `@fromBackingInt` (not `@intFromEnum` / `@enumFromInt`). `Key` has backing `u16`, so converting a read `u8` needs `@fromBackingInt(@intCast(byte))`.
- `zig fmt` auto-rewrites the enum builtins, but also reflows array literals that contain inline comments. Keep explanatory comments **outside** array literals (this is why the `c_keywords` comment in `src/syntax.zig` sits above the array).
- Migration details and before/after examples are documented in `zig-0.17.0/README.md`.

## Repository conventions

- Root `.gitignore` covers `zig-out/`, `zig-cache/`, `.zig-cache/`, `a.txt`, `main`. Never commit build artifacts.
- The root `README.md` is a placeholder ("hello world"); real documentation lives in `zig-0.17.0/README.md`.
- `.opencode/skills/` is an **untrusted nested Git repo** and intentionally untracked. Never `git add .opencode` or commit it directly — it would become an embedded repo/gitlink.
