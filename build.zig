const std = @import("std");

const pkgs = struct {
    const uri = std.build.Pkg{
        .name = "uri",
        .path = "./deps/uri/uri.zig",
    };
    const args = std.build.Pkg{
        .name = "args",
        .path = "./deps/args/args.zig",
    };
    const network = std.build.Pkg{
        .name = "network",
        .path = "./deps/network/network.zig",
    };
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const strip = b.option(bool, "strip", "Strips the resulting executable.") orelse (mode != .Debug);

    const exe = b.addExecutable("ftz", "src/main.zig");
    exe.addPackage(pkgs.uri);
    exe.addPackage(pkgs.args);
    exe.addPackage(pkgs.network);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.strip = strip;
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_cmd = b.addTest("src/main.zig");
    test_cmd.addPackage(pkgs.uri);
    test_cmd.addPackage(pkgs.args);
    test_cmd.addPackage(pkgs.network);

    const test_step = b.step("test", "Tests the implementation");
    test_step.dependOn(&test_cmd.step);
}
