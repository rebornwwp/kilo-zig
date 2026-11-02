//! kilo 的构建脚本（Zig 0.17.0）。
//!
//! 这个项目没有单独的库和测试目标，只生成一个可执行文件 `kilo`，
//! 并额外提供 `zig build run` 方便直接运行。

const std = @import("std");

pub fn build(b: *std.Build) void {
    // 允许通过 -Dtarget / -Doptimize 覆盖默认目标与优化级别。
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 生成可执行文件。kilo 需要 libc 提供的 isatty、ioctl、gettimeofday。
    const exe = b.addExecutable(.{
        .name = "kilo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // zig build 默认把产物安装到 zig-out/bin/kilo。
    b.installArtifact(exe);

    // zig build run -- <filename>
    // 先确保程序已经安装，再把命令行参数透传给 kilo。
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Zig 0.17 推荐使用 addPassthruArgs，避免运行参数污染配置缓存。
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run kilo");
    run_step.dependOn(&run_cmd.step);
}
