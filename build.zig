const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const graphql_mod = b.addModule("graphql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gql_tests = b.addTest(.{
        .root_module = graphql_mod,
    });

    const run_gql_tests = b.addRunArtifact(gql_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_gql_tests.step);
}
