const std = @import("std");
const build_tools = @import("../build_tools.zig");

const repo = "https://github.com/xiph/speexdsp.git";
const pinned_commit = "7a158783df74efe7c2d1c6ee8363c1e695c71226";
const include_dirs: []const []const u8 = &.{
    "include",
    "libspeexdsp",
};
const c_flags: []const []const u8 = &.{
    "-fwrapv",
};
const macro_defines: []const build_tools.MacroDefine = &.{
    .{ .name = "USE_KISS_FFT" },
    .{ .name = "FLOATING_POINT" },
    .{ .name = "EXPORT", .value = "" },
};
const c_sources: []const []const u8 = &.{
    "libspeexdsp/preprocess.c",
    "libspeexdsp/jitter.c",
    "libspeexdsp/mdf.c",
    "libspeexdsp/fftwrap.c",
    "libspeexdsp/filterbank.c",
    "libspeexdsp/resample.c",
    "libspeexdsp/buffer.c",
    "libspeexdsp/scal.c",
    "libspeexdsp/kiss_fft.c",
    "libspeexdsp/kiss_fftr.c",
};

pub fn addTo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) build_tools.ExternalStaticLibraryModule {
    return build_tools.addStaticLibraryModule(b, "speexdsp", .{
        .c_repo_src = .{
            .git_repo = repo,
            .commit = pinned_commit,
        },
        .library = .{
            .name = "speexdsp",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_c = .off,
            }),
        },
        .module = .{
            .root_source_file = b.path("third_party/speexdsp/src.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
        .include_dirs = include_dirs,
        .user_define_option = .{
            .name = "speexdsp_define",
            .description = "Optional user C macro for speexdsp; pass with -Dspeexdsp_define=NAME or -Dspeexdsp_define=NAME=VALUE",
            .macro_defines = macro_defines,
        },
        .c_sources = c_sources,
        .c_flags = c_flags,
        .command = &.{
            "/bin/sh",
            "-c",
            "mkdir -p \"$TP_SOURCE_ROOT/include/speex\"; cp -f 'third_party/speexdsp/config_types.h' \"$TP_SOURCE_ROOT/include/speex/speexdsp_config_types.h\"",
        },
    });
}
