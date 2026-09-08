const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maybe_registry = b.option(std.Build.LazyPath, "registry", "Path to the Vulkan registry (vk.xml); defaults to $VULKAN_SDK/share/vulkan/registry/vk.xml");
    const registry_path: std.Build.LazyPath = maybe_registry orelse blk: {
        const vk_sdk_path = b.graph.environ_map.get("VULKAN_SDK") orelse
            @panic("zephyr: pass -Dregistry=<path to vk.xml>, or set VULKAN_SDK");
        break :blk .{ .cwd_relative = b.fmt("{s}/share/vulkan/registry/vk.xml", .{vk_sdk_path}) };
    };

    // Pure-Zig XML pull parser (ianprime0509/zig-xml). vk.xml is parsed with
    // a real conforming parser rather than substring scanning, so malformed
    // input yields error.MalformedXml with a location instead of a panic.
    const xml_dep = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });

    // Public library module: the generator's own parser/emitter, reusable
    // by anything that wants to run it programmatically (and what fixes
    // this file's previously-dangling `@import("zephyr")`).
    const zephyr_mod = b.addModule("zephyr", .{
        .root_source_file = b.path("src/zephyr.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xml", .module = xml_dep.module("xml") },
        },
    });

    // CLI entry point: `vk_generator <vk.xml path> <output vk.zig path>`.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zephyr", .module = zephyr_mod },
        },
    });
    const cli_exe = b.addExecutable(.{
        .name = "vk_generator",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    // Runs the generator at build time and exposes the result as the
    // public "vk" module -- what the root project (or anything else
    // depending on this package) actually consumes.
    const gen_run = b.addRunArtifact(cli_exe);
    gen_run.addFileArg(registry_path);
    const vk_zig_source = gen_run.addOutputFileArg("vk.zig");

    const vk_module = b.addModule("vk", .{
        .root_source_file = vk_zig_source,
        .target = target,
        .optimize = optimize,
    });
    const vk_lib_name = if (target.result.os.tag == .windows) "vulkan-1" else "vulkan";
    vk_module.linkSystemLibrary(vk_lib_name, .{});

    const run_step = b.step("run", "Run the vk_generator CLI");
    const run_cmd = b.addRunArtifact(cli_exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = cli_mod,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const zephyr_tests = b.addTest(.{
        .root_module = zephyr_mod,
    });
    const run_zephyr_tests = b.addRunArtifact(zephyr_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_zephyr_tests.step);
}
