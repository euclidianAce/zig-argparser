const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("arg-parser-scratch", "src/test.zig");
    exe.setBuildMode(mode);
    exe.setTarget(target);
    exe.install();
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args|
        run_cmd.addArgs(args);
    const run_step = b.step("run", "run src/test.zig");
    run_step.dependOn(&run_cmd.step);
}
