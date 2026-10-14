const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("bazig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    // miniaudio, unmodified at the tag pinned in build.zig.zon. Its miniaudio.c only defines
    // MINIAUDIO_IMPLEMENTATION and includes the header.
    const miniaudio = b.dependency("miniaudio", .{});
    mod.addCSourceFile(.{
        .file = miniaudio.path("miniaudio.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    // The miniaudio header, translated by the translate-c package (Zig 0.17 has no @cImport; `default_init`: C struct
    // fields start zeroed, as the old built-in translation had them).
    const translate_c = b.dependency("translate_c", .{});
    const miniaudio_c: Translator = .init(translate_c, .{
        .c_source_file = miniaudio.path("miniaudio.h"),
        .target = target,
        .optimize = optimize,
        .default_init = true,
    });
    mod.addImport("miniaudio_c", miniaudio_c.mod);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // `zig build example`: sounds made with `synth`, written as WAV files and played from memory
    // through a device-less engine.
    const example = b.addExecutable(.{
        .name = "synth_sounds",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/synth_sounds.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bazig", .module = mod }},
        }),
    });
    const example_step = b.step("example", "Run the synth example (writes WAV files)");
    const run_example = b.addRunArtifact(example);
    run_example.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "sounds" } });
    example_step.dependOn(&run_example.step);

    // `zig build bench`: examples/bench.zig, what a sound costs to render. Always ReleaseFast.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "bazig", .module = mod }},
        }),
    });
    b.step("bench", "Measure what a sound costs to render (ReleaseFast)").dependOn(&b.addRunArtifact(bench).step);
}
