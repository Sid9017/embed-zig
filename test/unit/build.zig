const std = @import("std");
const Step = std.Build.Step;

/// Run test exe with stderr non-TTY so each test prints a line; pipefail preserves exit status.
fn addTestBinRunPreservingExit(b: *std.Build, step_name: []const u8, test_exe: *std.Build.Step.Compile) *Step.Run {
    const run = Step.Run.create(b, step_name);
    run.has_side_effects = true;
    run.step.dependOn(&test_exe.step);
    if (@import("builtin").os.tag == .windows) {
        run.addFileArg(test_exe.getEmittedBin());
    } else {
        run.addArgs(&.{ "bash", "-c", "set -o pipefail; \"$1\" 2>&1 | cat", "--" });
        run.addFileArg(test_exe.getEmittedBin());
    }
    return run;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("embed_zig", .{
        .target = target,
        .optimize = optimize,
        .speexdsp = true,
        .stb_truetype = true,
    });

    const embed_mod = dep.module("embed");

    const test_root = b.createModule(.{
        .root_source_file = b.path("mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root.addImport("embed", embed_mod);

    const tests = b.addTest(.{ .root_module = test_root });
    tests.linkLibrary(dep.artifact("embed_link"));
    const run_tests = b.addRunArtifact(tests);

    b.default_step.dependOn(&tests.step);
    b.step("test", "Run all unit tests").dependOn(&run_tests.step);

    const run_terminal = addTestBinRunPreservingExit(b, "run unit tests (terminal)", tests);
    b.step("test-terminal", "Run all unit tests with per-test OK lines (no listen)").dependOn(&run_terminal.step);

    const domains = [_]struct {
        step: []const u8,
        desc: []const u8,
        filters: []const []const u8,
    }{
        .{
            .step = "test-audio",
            .desc = "Audio-related unit tests",
            .filters = &.{
                "pkg.audio.",
                "hal.audio_system",
                "hal.i2s_test",
                "hal.mic_test",
                "hal.speaker_test",
                "pkg.drivers.es7210",
                "pkg.drivers.es8311",
                "third_party.speexdsp",
            },
        },
        .{ .step = "test-ble", .desc = "BLE unit tests", .filters = &.{"pkg.ble."} },
        .{
            .step = "test-ui",
            .desc = "UI unit tests",
            .filters = &.{
                "hal.display_test",
                "hal.led_strip_test",
                "hal.led_test",
                "pkg.ui.",
                "websim.hal.",
            },
        },
        .{ .step = "test-event", .desc = "Event bus unit tests", .filters = &.{"pkg.event."} },
        .{ .step = "test-cellular", .desc = "Cellular (pkg/cellular) unit tests", .filters = &.{"pkg.cellular."} },
    };

    inline for (domains) |d| {
        const dt = b.addTest(.{
            .name = d.step,
            .root_module = test_root,
            .filters = d.filters,
        });
        dt.linkLibrary(dep.artifact("embed_link"));
        const run_d = addTestBinRunPreservingExit(b, b.fmt("run {s}", .{d.step}), dt);
        b.step(d.step, d.desc).dependOn(&run_d.step);
    }
}
