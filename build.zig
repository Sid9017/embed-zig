const std = @import("std");
const portaudio_repo = "https://github.com/PortAudio/portaudio.git";
const portaudio_source_path = "third_party/portaudio/vendor/portaudio";
const portaudio_commit = "147dd722548358763a8b649b3e4b41dfffbcfbb6";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const portaudio_define = b.option([]const u8, "portaudio_define", "Optional user C macro for portaudio (NAME or NAME=VALUE)");
    const ensure_portaudio_source = ensurePortaudioSource(b);
    const speexdsp_mod = b.createModule(.{
        .root_source_file = b.path("third_party/speexdsp/src.zig"),
        .target = target,
        .optimize = optimize,
    });
    speexdsp_mod.addIncludePath(b.path("third_party/speexdsp/c_include"));
    const portaudio_mod = b.createModule(.{
        .root_source_file = b.path("third_party/portaudio/src.zig"),
        .target = target,
        .optimize = optimize,
    });
    portaudio_mod.addIncludePath(b.path("third_party/portaudio/c_include"));
    applyUserDefine(portaudio_mod, portaudio_define);

    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/root.zig"),
    });
    const resampler_mod = b.createModule(.{
        .root_source_file = b.path("src/pkg/audio/resampler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "speexdsp", .module = speexdsp_mod },
        },
    });
    const override_buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/pkg/audio/override_buffer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
        },
    });
    const mixer_mod = b.createModule(.{
        .root_source_file = b.path("src/pkg/audio/mixer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "speexdsp", .module = speexdsp_mod },
            .{ .name = "resampler", .module = resampler_mod },
        },
    });
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/pkg/audio/engine.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "mixer", .module = mixer_mod },
            .{ .name = "override_buffer", .module = override_buffer_mod },
            .{ .name = "resampler", .module = resampler_mod },
        },
    });

    // Build speexdsp C static library for tests that execute resampling APIs.
    const wf = b.addWriteFiles();
    const empty_root = wf.add("empty.zig", "");
    const speexdsp_lib = b.addLibrary(.{
        .name = "speexdsp_for_tests",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = empty_root,
            .target = target,
            .optimize = optimize,
        }),
    });
    speexdsp_lib.linkLibC();

    const c_flags: []const []const u8 = &.{ "-DUSE_KISS_FFT", "-DFLOATING_POINT", "-DEXPORT=", "-fwrapv" };
    const c_sources = [_][]const u8{
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/preprocess.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/jitter.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/mdf.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/fftwrap.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/filterbank.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/resample.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/buffer.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/scal.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/kiss_fft.c",
        "third_party/speexdsp/vendor/speexdsp/libspeexdsp/kiss_fftr.c",
    };
    for (c_sources) |src| {
        speexdsp_lib.addCSourceFile(.{ .file = b.path(src), .flags = c_flags });
    }
    speexdsp_lib.addIncludePath(b.path("third_party/speexdsp/c_include"));
    speexdsp_lib.addIncludePath(b.path("third_party/speexdsp/vendor/speexdsp/libspeexdsp"));

    const portaudio_lib = b.addLibrary(.{
        .name = "portaudio_for_apps",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = empty_root,
            .target = target,
            .optimize = optimize,
        }),
    });
    portaudio_lib.linkLibC();
    const pa_common_sources = [_][]const u8{
        "third_party/portaudio/vendor/portaudio/src/common/pa_allocation.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_converters.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_cpuload.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_debugprint.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_dither.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_front.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_process.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_ringbuffer.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_stream.c",
        "third_party/portaudio/vendor/portaudio/src/common/pa_trace.c",
    };
    for (pa_common_sources) |src| {
        portaudio_lib.addCSourceFile(.{ .file = b.path(src) });
    }
    switch (target.result.os.tag) {
        .macos => {
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/os/unix/pa_unix_hostapis.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/os/unix/pa_unix_util.c") });
            portaudio_lib.root_module.addCMacro("PA_USE_COREAUDIO", "1");
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/hostapi/coreaudio/pa_mac_core.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/hostapi/coreaudio/pa_mac_core_blocking.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/hostapi/coreaudio/pa_mac_core_utilities.c") });
            portaudio_lib.linkFramework("AudioToolbox");
            portaudio_lib.linkFramework("AudioUnit");
            portaudio_lib.linkFramework("CoreAudio");
            portaudio_lib.linkFramework("CoreFoundation");
            portaudio_lib.linkFramework("Carbon");
        },
        .linux => {
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/os/unix/pa_unix_hostapis.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/os/unix/pa_unix_util.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            portaudio_lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
        .windows => {
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/os/win/pa_win_hostapis.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/os/win/pa_win_util.c") });
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            portaudio_lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
        else => {
            portaudio_lib.addCSourceFile(.{ .file = b.path("third_party/portaudio/vendor/portaudio/src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            portaudio_lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
    }
    portaudio_lib.addIncludePath(b.path("third_party/portaudio/c_include"));
    portaudio_lib.addIncludePath(b.path("third_party/portaudio/vendor/portaudio/include"));
    portaudio_lib.addIncludePath(b.path("third_party/portaudio/vendor/portaudio/src/common"));
    portaudio_lib.addIncludePath(b.path("third_party/portaudio/vendor/portaudio/src/os/unix"));
    portaudio_lib.addIncludePath(b.path("third_party/portaudio/vendor/portaudio/src/os/win"));
    portaudio_lib.addIncludePath(b.path("third_party/portaudio/vendor/portaudio/src/hostapi/coreaudio"));
    portaudio_lib.addIncludePath(b.path("third_party/portaudio/vendor/portaudio/src/hostapi/skeleton"));
    applyUserDefine(portaudio_lib.root_module, portaudio_define);
    portaudio_lib.step.dependOn(ensure_portaudio_source);

    const runtime_std_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/std.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_runtime_std_tests = b.addRunArtifact(runtime_std_tests);

    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "portaudio", .module = portaudio_mod },
            },
        }),
    });
    root_tests.step.dependOn(ensure_portaudio_source);
    root_tests.linkLibrary(portaudio_lib);
    const run_root_tests = b.addRunArtifact(root_tests);

    const async_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pkg/async/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    const run_async_tests = b.addRunArtifact(async_tests);

    const event_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pkg/event/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    const run_event_tests = b.addRunArtifact(event_tests);

    const event_mod = b.createModule(.{
        .root_source_file = b.path("src/pkg/event/root.zig"),
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
        },
    });
    const button_gesture_mod = b.createModule(.{
        .root_source_file = b.path("src/pkg/input/button/gesture.zig"),
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
        },
    });
    button_gesture_mod.addImport("event", event_mod);

    const event_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pkg/event/bus_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
                .{ .name = "event", .module = event_mod },
                .{ .name = "button_gesture", .module = button_gesture_mod },
            },
        }),
    });
    const run_event_integration_tests = b.addRunArtifact(event_integration_tests);

    const audio_resampler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pkg/audio/resampler.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "speexdsp", .module = speexdsp_mod },
                .{ .name = "portaudio", .module = portaudio_mod },
            },
        }),
    });
    audio_resampler_tests.linkLibrary(speexdsp_lib);
    audio_resampler_tests.step.dependOn(ensure_portaudio_source);
    audio_resampler_tests.linkLibrary(portaudio_lib);
    const run_audio_resampler_tests = b.addRunArtifact(audio_resampler_tests);

    const audio_mixer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pkg/audio/mixer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
                .{ .name = "speexdsp", .module = speexdsp_mod },
                .{ .name = "resampler", .module = resampler_mod },
                .{ .name = "portaudio", .module = portaudio_mod },
            },
        }),
    });
    audio_mixer_tests.linkLibrary(speexdsp_lib);
    audio_mixer_tests.step.dependOn(ensure_portaudio_source);
    audio_mixer_tests.linkLibrary(portaudio_lib);
    const run_audio_mixer_tests = b.addRunArtifact(audio_mixer_tests);

    const audio_engine_exe = b.addExecutable(.{
        .name = "audio_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/audio_engine/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
                .{ .name = "portaudio", .module = portaudio_mod },
                .{ .name = "mixer", .module = mixer_mod },
                .{ .name = "engine", .module = engine_mod },
                .{ .name = "speexdsp", .module = speexdsp_mod },
            },
        }),
    });
    audio_engine_exe.linkLibrary(speexdsp_lib);
    audio_engine_exe.linkLibrary(portaudio_lib);
    audio_engine_exe.step.dependOn(ensure_portaudio_source);
    const run_audio_engine = b.addRunArtifact(audio_engine_exe);
    if (b.args) |args| run_audio_engine.addArgs(args);
    const audio_engine_step = b.step("audio-engine", "Run audio engine demo (play / aec)");
    audio_engine_step.dependOn(&run_audio_engine.step);
    const build_audio_engine_step = b.step("build-audio-engine", "Build audio engine demo");
    build_audio_engine_step.dependOn(&audio_engine_exe.step);

    const net_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pkg/net/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    const run_net_tests = b.addRunArtifact(net_tests);

    const audio_override_buffer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pkg/audio/override_buffer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    const run_audio_override_buffer_tests = b.addRunArtifact(audio_override_buffer_tests);

    const audio_test_step = b.step("test-audio", "Run audio package tests");
    audio_test_step.dependOn(&run_audio_resampler_tests.step);
    audio_test_step.dependOn(&run_audio_mixer_tests.step);
    audio_test_step.dependOn(&run_audio_override_buffer_tests.step);

    const net_test_step = b.step("test-net", "Run net package tests");
    net_test_step.dependOn(&run_net_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_runtime_std_tests.step);
    test_step.dependOn(&run_root_tests.step);
    test_step.dependOn(&run_async_tests.step);
    test_step.dependOn(&run_event_tests.step);
    test_step.dependOn(&run_event_integration_tests.step);
    test_step.dependOn(&run_audio_resampler_tests.step);
    test_step.dependOn(&run_audio_mixer_tests.step);
    test_step.dependOn(&run_audio_override_buffer_tests.step);
    test_step.dependOn(&run_net_tests.step);

    // ESP compile-only checks.
    // Uses addObject because extern symbols from espz can't link on host.
    const espz_dep = b.dependency("espz", .{});
    const esp_mod = espz_dep.module("espz");
    const hal_mod = b.createModule(.{
        .root_source_file = b.path("src/hal/root.zig"),
    });
    const es7210_driver_mod = b.createModule(.{
        .root_source_file = b.path("src/pkg/drivers/es7210/src.zig"),
        .target = target,
        .optimize = optimize,
    });
    const es8311_driver_mod = b.createModule(.{
        .root_source_file = b.path("src/pkg/drivers/es8311/src.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hal", .module = hal_mod },
        },
    });

    const esp_runtime_check = b.addObject(.{
        .name = "esp_runtime_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/esp/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
                .{ .name = "esp", .module = esp_mod },
            },
        }),
    });

    const esp_hal_check = b.addObject(.{
        .name = "esp_hal_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/esp/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hal", .module = hal_mod },
                .{ .name = "esp", .module = esp_mod },
                .{ .name = "es7210_driver", .module = es7210_driver_mod },
                .{ .name = "es8311_driver", .module = es8311_driver_mod },
            },
        }),
    });

    const check_step = b.step("check-esp", "Compile-check ESP modules");
    check_step.dependOn(&esp_runtime_check.step);
    check_step.dependOn(&esp_hal_check.step);
}

fn ensurePortaudioSource(b: *std.Build) *std.Build.Step {
    const clone_or_fetch = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        b.fmt(
            "set -eu; " ++
                "if [ ! -d '{s}/.git' ]; then " ++
                "  mkdir -p \"$(dirname '{s}')\"; " ++
                "  git clone --depth 1 {s} '{s}'; " ++
                "fi",
            .{ portaudio_source_path, portaudio_source_path, portaudio_repo, portaudio_source_path },
        ),
    });

    const checkout = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        b.fmt(
            "set -eu; " ++
                "if git -C '{s}' rev-parse --verify {s} >/dev/null 2>&1; then " ++
                "  git -C '{s}' checkout --detach {s}; " ++
                "else " ++
                "  git -C '{s}' fetch --depth 1 origin {s}; " ++
                "  git -C '{s}' checkout --detach FETCH_HEAD; " ++
                "fi",
            .{ portaudio_source_path, portaudio_commit, portaudio_source_path, portaudio_commit, portaudio_source_path, portaudio_commit, portaudio_source_path },
        ),
    });
    checkout.step.dependOn(&clone_or_fetch.step);

    const sync_headers = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        b.fmt(
            "set -eu; " ++
                "mkdir -p third_party/portaudio/c_include; " ++
                "cp -f {s}/include/*.h third_party/portaudio/c_include/",
            .{portaudio_source_path},
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
