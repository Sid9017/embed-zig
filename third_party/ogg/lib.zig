const std = @import("std");
const build_tools = @import("../build_tools.zig");

const default_repo = "https://github.com/xiph/ogg.git";
const pinned_commit = "06a5e0262cdc28aa4ae6797627a783b5010440f0";
const c_sources: []const []const u8 = &.{
    "src/bitwise.c",
    "src/framing.c",
};
const include_dirs: []const []const u8 = &.{
    "include",
    "include/ogg",
};

pub fn addTo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) build_tools.ExternalStaticLibraryModule {
    return build_tools.addStaticLibraryModule(b, "ogg", .{
        .c_repo_src = .{
            .git_repo = default_repo,
            .commit = pinned_commit,
        },
        .library = .{
            .name = "ogg",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        },
        .module = .{
            .root_source_file = b.path("third_party/ogg/src.zig"),
            .target = target,
            .optimize = optimize,
        },
        .include_dirs = include_dirs,
        .user_define_option = .{
            .name = "ogg_define",
            .description = "Optional user C macro for ogg; pass with -Dogg_define=NAME or -Dogg_define=NAME=VALUE",
        },
        .c_sources = c_sources,
        .command = &.{
            "/bin/sh",
            "-c",
            "mkdir -p \"$TP_SOURCE_ROOT/include/ogg\"; cp -f 'third_party/ogg/config_types.h' \"$TP_SOURCE_ROOT/include/ogg/config_types.h\"",
        },
    });
}
