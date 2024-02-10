const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;
const sokol = @import("sokol");
const zmesh = @import("zmesh");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    // special case handling for native vs web build
    if (target.result.isWasm()) {
        try buildWeb(b, target, optimize, dep_sokol);
    } else {
        try buildNative(b, target, optimize, dep_sokol);
    }
}

// this is the regular build for all native platforms, nothing surprising here
fn buildNative(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, dep_sokol: *Build.Dependency) !void {
    const my_template = b.addExecutable(.{
        .name = "my_template",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/main.zig" },
    });
    //my_template.root_module.addImport("sokol", dep_sokol.module("sokol"));
    try setup_links(b, target, optimize, my_template, dep_sokol);

    b.installArtifact(my_template);
    const run = b.addRunArtifact(my_template);
    b.step("run", "Run my_template").dependOn(&run.step);
}

// for web builds, the Zig code needs to be built into a library and linked with the Emscripten linker
fn buildWeb(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, dep_sokol: *Build.Dependency) !void {
    const my_template = b.addStaticLibrary(.{
        .name = "my_template",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/main.zig" },
    });
    //my_template.root_module.addImport("sokol", dep_sokol.module("sokol"));
    try setup_links(b, target, optimize, my_template, dep_sokol);

    // create a build step which invokes the Emscripten linker
    const emsdk = dep_sokol.builder.dependency("emsdk", .{});
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = my_template,
        .target = target,
        .optimize = optimize,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .shell_file_path = dep_sokol.path("src/sokol/web/shell.html").getPath(b),
    });
    // ...and a special run step to start the web build output via 'emrun'
    const run = sokol.emRunStep(b, .{ .name = "my_template", .emsdk = emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run my_template").dependOn(&run.step);
}

fn setup_links(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, step_compile: *Build.Step.Compile, dep_sokol: *Build.Dependency) !void {
    try append_library(b, target, optimize, step_compile, "assets", "assets/assets.zig");

    try append_dependency(b, target, optimize, step_compile, "ziglua");

    step_compile.root_module.addImport("sokol", dep_sokol.module("sokol"));

    const zmesh_pkg = zmesh.package(b, target, optimize, .{});
    zmesh_pkg.link(step_compile);
}

fn append_library(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, step_compile: *Build.Step.Compile, comptime name: []const u8, comptime src_path: []const u8) !void {
    const asset_lib = b.addStaticLibrary(.{
        .name = name,
        .root_source_file = .{ .path = src_path },
        .target = target,
        .optimize = optimize,
    });
    step_compile.linkLibrary(asset_lib);
    b.installArtifact(asset_lib);
}

fn append_module(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, step_compile: *Build.Step.Compile, comptime module_name: []const u8) !void {
    step_compile.root_module.addImport(module_name, b.dependency(module_name, .{
        .target = target,
        .optimize = optimize,
    }).module(module_name));
}

fn append_dependency(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, step_compile: *Build.Step.Compile, comptime module_name: []const u8) !void {
    const dependency_module = b.dependency(module_name, .{
        .target = target,
        .optimize = optimize,
    });
    step_compile.root_module.addImport(module_name, dependency_module.module(module_name));
}

fn create_delve_module(b: *std.Build, target: Build.ResolvedTarget, optimize: OptimizeMode) *Build.Module {
    const delve_module = b.addModule("delve", .{
        .root_source_file = .{ .path = "src/framework/delve.zig" },
    });

    const zmesh_pkg = zmesh.package(b, target, optimize, .{});

    delve_module.addImport("zmesh", zmesh_pkg.zmesh);

    return delve_module;
}

fn create_delve_lib(b: *std.Build, target: Build.ResolvedTarget, optimize: OptimizeMode) *Build.Step.Compile {
    // Delve library artifact
    const lib_opts = .{
        .name = "delve",
        .target = target,
        .optimize = optimize,
    };

    // make the Delve library as a static lib
    const lib = b.addStaticLibrary(lib_opts);
    lib.addCSourceFile(.{ .file = .{ .path = "libs/stb_image-2.28/stb_image_impl.c" }, .flags = &[_][]const u8{"-std=c99"} });
    lib.addIncludePath(.{ .path = "libs/stb_image-2.28" });

    // let users of our library get access to some headers
    lib.installHeader("libs/stb_image-2.28/stb_image.h", "stb_image.h");

    b.installArtifact(lib);
    return lib;
}
