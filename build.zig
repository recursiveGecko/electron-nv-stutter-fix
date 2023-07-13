const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const exe = try buildExe(b, "electron-nv-stutter-fix", optimize);

    if (b.option(bool, "build-small", "Build a version with ReleaseSmall") orelse false) {
        _ = try buildExe(b, "electron-nv-stutter-fix-small", .ReleaseSmall);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn buildExe(
    b: *std.Build,
    name: []const u8,
    optimize_mode: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = "src/main.zig" },
        .target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = "x86_64-windows-msvc" }),
        .optimize = optimize_mode,
    });
    exe.linkLibC();
    exe.addIncludePath("lib/nvapi/R535-OpenSource");
    exe.addAnonymousModule("yazap", .{
        .source_file = .{ .path = "lib/yazap/src/lib.zig" },
    });

    b.installArtifact(exe);
    return exe;
}
