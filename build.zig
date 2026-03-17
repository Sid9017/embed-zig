const std = @import("std");
const portaudio_pkg = @import("src/third_party/portaudio/lib.zig");
const speexdsp_pkg = @import("src/third_party/speexdsp/lib.zig");
const opus_pkg = @import("src/third_party/opus/lib.zig");
const ogg_pkg = @import("src/third_party/ogg/lib.zig");
const stb_truetype_pkg = @import("src/third_party/stb_truetype/lib.zig");

pub const LinkOptions = struct {
    portaudio: bool = false,
    speexdsp: bool = false,
    opus: bool = false,
    ogg: bool = false,
    stb_truetype: bool = false,

    pub fn withBuildOptions(
        self: @This(),
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) Options {
        return .{
            .target = target,
            .optimize = optimize,
            .portaudio = self.portaudio,
            .speexdsp = self.speexdsp,
            .opus = self.opus,
            .ogg = self.ogg,
            .stb_truetype = self.stb_truetype,
        };
    }
};

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    portaudio: bool = false,
    speexdsp: bool = false,
    opus: bool = false,
    ogg: bool = false,
    stb_truetype: bool = false,
};

pub fn readEmbedOptions(b: *std.Build) LinkOptions {
    return .{
        .portaudio = b.option(bool, "portaudio", "Enable portaudio in exported embed link") orelse false,
        .speexdsp = b.option(bool, "speexdsp", "Enable speexdsp in exported embed link") orelse false,
        .opus = b.option(bool, "opus", "Enable opus in exported embed link") orelse false,
        .ogg = b.option(bool, "ogg", "Enable ogg in exported embed link") orelse false,
        .stb_truetype = b.option(bool, "stb_truetype", "Enable stb_truetype in exported embed link") orelse false,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const export_options = readEmbedOptions(b);

    // -- Third-party (module + static library) --
    const pa = portaudio_pkg.addTo(b, target, optimize);
    const spx = speexdsp_pkg.addTo(b, target, optimize);
    const opus = opus_pkg.addTo(b, target, optimize);
    const ogg = ogg_pkg.addLibrary(b, target, optimize);
    const stb_tt = stb_truetype_pkg.addTo(b, target, optimize);
    // ===================================================================
    // Project module
    // ===================================================================

    const embed_mod = b.addModule("embed", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    portaudio_pkg.configureModule(b, embed_mod, target);
    speexdsp_pkg.configureModule(b, embed_mod);
    opus_pkg.configureModule(b, embed_mod);
    ogg_pkg.configureModule(b, embed_mod);
    stb_truetype_pkg.configureModule(b, embed_mod);

    const files = b.addWriteFiles();
    const empty_root = files.add("empty.zig", "");
    const embed_link_root = b.createModule(.{
        .root_source_file = empty_root,
        .target = target,
        .optimize = optimize,
    });
    const embed_link = b.addLibrary(.{
        .name = "embed_link",
        .linkage = .static,
        .root_module = embed_link_root,
    });
    if (export_options.portaudio) {
        embed_link.linkLibrary(pa);
    }
    if (export_options.speexdsp) {
        embed_link.linkLibrary(spx);
    }
    if (export_options.opus) {
        embed_link.linkLibrary(opus);
    }
    if (export_options.ogg) {
        embed_link.linkLibrary(ogg);
    }
    if (export_options.stb_truetype) {
        embed_link.linkLibrary(stb_tt);
    }

    b.installArtifact(embed_link);

    // 110-cellular firmware mock test (no esp-zig): run test "run with mock hw" in app.zig
    const app_zig = b.path("test/firmware/110-cellular/app.zig");
    const esp_mock_src = b.path("test/firmware/110-cellular/esp_mock.zig");
    const esp_mock_mod = b.createModule(.{
        .root_source_file = esp_mock_src,
        .target = target,
        .optimize = optimize,
    });
    esp_mock_mod.addImport("embed", embed_mod);

    const app_root = b.createModule(.{
        .root_source_file = app_zig,
        .target = target,
        .optimize = optimize,
    });
    app_root.addImport("esp", esp_mock_mod);

    const firmware_test = b.addTest(.{
        .root_module = app_root,
    });
    const run_firmware_test = b.addRunArtifact(firmware_test);
    b.step("test-110-cellular-firmware", "Run 110-cellular firmware mock test (no esp-zig)").dependOn(&run_firmware_test.step);
}
