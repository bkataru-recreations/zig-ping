const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const exe = b.addExecutable(.{ .name = "zig-ping", .root_source_file = b.path("main.zig"), .target = target });

    b.installArtifact(exe);
}
