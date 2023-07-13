const std = @import("std");

pub fn build(b: *std.Build) !void {
    // const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "electron-nv-stutter-fix",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = try std.zig.CrossTarget.parse(.{.arch_os_abi = "x86_64-windows-msvc"}),
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.addIncludePath("lib/nvapi/R535-OpenSource");

    exe.addAnonymousModule("yazap", .{
        .source_file = .{ .path = "lib/yazap/src/lib.zig" },
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
