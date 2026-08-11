const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- The CLAP plugin (a shared library exporting `clap_entry`) ----
    const plugin_mod = b.createModule(.{
        .root_source_file = b.path("src/clap_plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Clay UI library (single-header C) plus its implementation TU.
    plugin_mod.addIncludePath(b.path("vendor/clay"));
    plugin_mod.addCSourceFile(.{ .file = b.path("src/gui/clay_impl.c"), .flags = &.{} });

    // stb_image decodes the baked GUI PNGs at editor-open time.
    plugin_mod.addIncludePath(b.path("vendor/stb"));
    plugin_mod.addCSourceFile(.{
        .file = b.path("src/gui/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });

    // Baked GUI art, embedded so the .clap ships as a single self-contained
    // file. Regenerate with `zig build assets` after changing the baker.
    plugin_mod.addAnonymousImport("knob_png", .{ .root_source_file = b.path("assets/knob.png") });
    plugin_mod.addAnonymousImport("tolex_png", .{ .root_source_file = b.path("assets/tolex.png") });

    // Win32 windowing + OpenGL used by the GUI backend.
    plugin_mod.linkSystemLibrary("user32", .{});
    plugin_mod.linkSystemLibrary("gdi32", .{});
    plugin_mod.linkSystemLibrary("opengl32", .{});
    plugin_mod.linkSystemLibrary("kernel32", .{});

    const plugin = b.addLibrary(.{
        .name = "OR120AmpSim",
        .root_module = plugin_mod,
        .linkage = .dynamic,
    });

    // Install the artifact renamed to the `.clap` extension.
    const install_clap = b.addInstallArtifact(plugin, .{
        .dest_dir = .{ .override = .{ .custom = "clap" } },
        .dest_sub_path = "OR120AmpSim.clap",
    });
    b.getInstallStep().dependOn(&install_clap.step);

    // ---- Unit tests (pure-Zig DSP) ----
    const dsp_mod = b.createModule(.{
        .root_source_file = b.path("src/dsp/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dsp_tests = b.addTest(.{ .root_module = dsp_mod });
    const run_dsp_tests = b.addRunArtifact(dsp_tests);

    const params_mod = b.createModule(.{
        .root_source_file = b.path("src/params.zig"),
        .target = target,
        .optimize = optimize,
    });
    const params_tests = b.addTest(.{ .root_module = params_mod });
    const run_params_tests = b.addRunArtifact(params_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_dsp_tests.step);
    test_step.dependOn(&run_params_tests.step);

    // ---- Scalar-vs-SIMD DSP benchmark ----
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "or120-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the scalar-vs-SIMD DSP benchmark");
    bench_step.dependOn(&run_bench.step);

    // ---- GUI asset baker ----
    // Renders assets/knob.png and assets/tolex.png. Always built optimized: it
    // is sampling-heavy and takes minutes in Debug.
    const baker_mod = b.createModule(.{
        .root_source_file = b.path("tools/bake_assets/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    baker_mod.addIncludePath(b.path("vendor/stb"));
    baker_mod.addCSourceFile(.{
        .file = b.path("tools/bake_assets/stb_write_impl.c"),
        .flags = &.{"-std=c99"},
    });
    const baker_exe = b.addExecutable(.{
        .name = "bake-assets",
        .root_module = baker_mod,
    });
    const run_baker = b.addRunArtifact(baker_exe);
    run_baker.setCwd(b.path("."));
    // Rendering is deterministic, so only re-run when explicitly asked.
    run_baker.has_side_effects = true;
    const assets_step = b.step("assets", "Bake the GUI raster assets into assets/");
    assets_step.dependOn(&run_baker.step);
}
