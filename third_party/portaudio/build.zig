const std = @import("std");

const default_repo = "https://github.com/PortAudio/portaudio.git";
const default_source_path = "vendor/portaudio";
const pinned_commit = "147dd722548358763a8b649b3e4b41dfffbcfbb6";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const portaudio_define = b.option([]const u8, "portaudio_define", "Optional user C macro for portaudio (NAME or NAME=VALUE)");

    const ensure_source = ensureSource(b);

    const wf = b.addWriteFiles();
    const empty_root = wf.add("empty.zig", "");
    const portaudio_lib = b.addLibrary(.{
        .name = "portaudio",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = empty_root,
            .target = target,
            .optimize = optimize,
        }),
    });
    portaudio_lib.linkLibC();

    const common_sources = [_][]const u8{
        "vendor/portaudio/src/common/pa_allocation.c",
        "vendor/portaudio/src/common/pa_converters.c",
        "vendor/portaudio/src/common/pa_cpuload.c",
        "vendor/portaudio/src/common/pa_debugprint.c",
        "vendor/portaudio/src/common/pa_dither.c",
        "vendor/portaudio/src/common/pa_front.c",
        "vendor/portaudio/src/common/pa_process.c",
        "vendor/portaudio/src/common/pa_ringbuffer.c",
        "vendor/portaudio/src/common/pa_stream.c",
        "vendor/portaudio/src/common/pa_trace.c",
    };
    for (common_sources) |src| {
        portaudio_lib.addCSourceFile(.{ .file = b.path(src) });
    }

    switch (target.result.os.tag) {
        .macos => {
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/os/unix/pa_unix_hostapis.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/os/unix/pa_unix_util.c") });
            portaudio_lib.root_module.addCMacro("PA_USE_COREAUDIO", "1");
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/hostapi/coreaudio/pa_mac_core.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/hostapi/coreaudio/pa_mac_core_blocking.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/hostapi/coreaudio/pa_mac_core_utilities.c") });
            portaudio_lib.linkFramework("AudioToolbox");
            portaudio_lib.linkFramework("AudioUnit");
            portaudio_lib.linkFramework("CoreAudio");
            portaudio_lib.linkFramework("CoreFoundation");
        },
        .linux => {
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/os/unix/pa_unix_hostapis.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/os/unix/pa_unix_util.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            portaudio_lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
        .windows => {
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/os/win/pa_win_hostapis.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/os/win/pa_win_util.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            portaudio_lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
        else => {
            portaudio_lib.addCSourceFile(.{ .file = b.path("vendor/portaudio/src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            portaudio_lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
    }

    portaudio_lib.addIncludePath(b.path("c_include"));
    portaudio_lib.addIncludePath(b.path("vendor/portaudio/src/common"));
    portaudio_lib.addIncludePath(b.path("vendor/portaudio/src/os/unix"));
    portaudio_lib.addIncludePath(b.path("vendor/portaudio/src/os/win"));
    portaudio_lib.addIncludePath(b.path("vendor/portaudio/src/hostapi/coreaudio"));
    portaudio_lib.addIncludePath(b.path("vendor/portaudio/src/hostapi/skeleton"));
    applyUserDefine(portaudio_lib.root_module, portaudio_define);
    portaudio_lib.step.dependOn(ensure_source);

    const portaudio_module = b.addModule("portaudio", .{
        .root_source_file = b.path("src.zig"),
        .target = target,
        .optimize = optimize,
    });
    portaudio_module.addIncludePath(b.path("c_include"));
    applyUserDefine(portaudio_module, portaudio_define);

    const test_step = b.step("test", "Run portaudio API tests");
    const test_compile = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_compile.root_module.addIncludePath(b.path("c_include"));
    applyUserDefine(test_compile.root_module, portaudio_define);
    test_compile.linkLibrary(portaudio_lib);
    test_compile.step.dependOn(ensure_source);
    test_step.dependOn(&b.addRunArtifact(test_compile).step);
}

fn ensureSource(b: *std.Build) *std.Build.Step {
    const clone_or_fetch = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        b.fmt(
            "set -eu; " ++
                "if [ ! -d '{s}/.git' ]; then " ++
                "  mkdir -p \"$(dirname '{s}')\"; " ++
                "  git clone --depth 1 {s} '{s}'; " ++
                "fi",
            .{ default_source_path, default_source_path, default_repo, default_source_path },
        ),
    });

    const checkout = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        b.fmt(
            "set -eu; " ++
                "git -C '{s}' fetch --depth 1 origin {s}; " ++
                "git -C '{s}' checkout --detach FETCH_HEAD",
            .{ default_source_path, pinned_commit, default_source_path },
        ),
    });
    checkout.step.dependOn(&clone_or_fetch.step);

    const sync_headers = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        b.fmt(
            "set -eu; " ++
                "mkdir -p c_include; " ++
                "cp -f {s}/include/portaudio.h c_include/",
            .{default_source_path},
        ),
    });
    sync_headers.step.dependOn(&checkout.step);

    return &sync_headers.step;
}

fn applyUserDefine(module: *std.Build.Module, define: ?[]const u8) void {
    if (define) |raw| {
        if (raw.len == 0) return;
        if (std.mem.indexOfScalar(u8, raw, '=')) |idx| {
            module.addCMacro(raw[0..idx], raw[idx + 1 ..]);
        } else {
            module.addCMacro(raw, "1");
        }
    }
}
