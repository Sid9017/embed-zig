const std = @import("std");

pub const Result = struct {
    module: *std.Build.Module,
    lib: *std.Build.Step.Compile,
};

pub fn addTo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Result {
    const module = b.addModule("stb_truetype", .{
        .root_source_file = b.path("third_party/stb_truetype/src.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("third_party/stb_truetype"));

    const files = b.addWriteFiles();
    const empty_root = files.add("empty.zig", "");
    const lib = b.addLibrary(.{
        .name = "stb_truetype",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = empty_root,
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
        }),
    });
    lib.linkLibC();
    lib.addIncludePath(b.path("third_party/stb_truetype"));
    lib.addCSourceFile(.{ .file = b.path("third_party/stb_truetype/stb_truetype_impl.c") });

    return .{
        .module = module,
        .lib = lib,
    };
}
