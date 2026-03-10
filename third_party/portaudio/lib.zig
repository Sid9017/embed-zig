const std = @import("std");
const build_tools = @import("../build_tools.zig");

const repo = "https://github.com/PortAudio/portaudio.git";
const pinned_commit = "147dd722548358763a8b649b3e4b41dfffbcfbb6";
const include_dirs: []const []const u8 = &.{
    "include",
    "src/common",
    "src/os/unix",
    "src/os/win",
    "src/hostapi/coreaudio",
    "src/hostapi/skeleton",
};
const common_c_sources: []const []const u8 = &.{
    "src/common/pa_allocation.c",
    "src/common/pa_converters.c",
    "src/common/pa_cpuload.c",
    "src/common/pa_debugprint.c",
    "src/common/pa_dither.c",
    "src/common/pa_front.c",
    "src/common/pa_process.c",
    "src/common/pa_ringbuffer.c",
    "src/common/pa_stream.c",
    "src/common/pa_trace.c",
};

pub fn addTo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) build_tools.ExternalStaticLibraryModule {
    const pa = build_tools.addStaticLibraryModule(b, "portaudio", .{
        .c_repo_src = .{
            .git_repo = repo,
            .commit = pinned_commit,
        },
        .library = .{
            .name = "portaudio",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_c = .off,
            }),
        },
        .module = .{
            .root_source_file = b.path("third_party/portaudio/src.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
        .include_dirs = include_dirs,
        .c_sources = common_c_sources,
    });

    switch (target.result.os.tag) {
        .macos => {
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/os/unix/pa_unix_hostapis.c") });
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/os/unix/pa_unix_util.c") });
            pa.lib.root_module.addCMacro("PA_USE_COREAUDIO", "1");
            pa.module.addCMacro("PA_USE_COREAUDIO", "1");
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/hostapi/coreaudio/pa_mac_core.c") });
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/hostapi/coreaudio/pa_mac_core_blocking.c") });
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/hostapi/coreaudio/pa_mac_core_utilities.c") });
            pa.lib.linkFramework("AudioToolbox");
            pa.lib.linkFramework("AudioUnit");
            pa.lib.linkFramework("CoreAudio");
            pa.lib.linkFramework("CoreFoundation");
            pa.lib.linkFramework("Carbon");
        },
        .linux => {
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/os/unix/pa_unix_hostapis.c") });
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/os/unix/pa_unix_util.c") });
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            pa.lib.root_module.addCMacro("PA_USE_SKELETON", "1");
            pa.module.addCMacro("PA_USE_SKELETON", "1");
        },
        .windows => {
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/os/win/pa_win_hostapis.c") });
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/os/win/pa_win_util.c") });
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            pa.lib.root_module.addCMacro("PA_USE_SKELETON", "1");
            pa.module.addCMacro("PA_USE_SKELETON", "1");
        },
        else => {
            pa.lib.addCSourceFile(.{ .file = pa.repo.sourcePath(b, "src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            pa.lib.root_module.addCMacro("PA_USE_SKELETON", "1");
            pa.module.addCMacro("PA_USE_SKELETON", "1");
        },
    }

    return pa;
}
