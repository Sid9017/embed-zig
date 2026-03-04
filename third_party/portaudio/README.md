# portaudio — Zig bindings for PortAudio

Zig-first bindings for [PortAudio](https://github.com/PortAudio/portaudio), a
cross-platform audio I/O library.

## Directory layout

```text
third_party/portaudio/
├── build.zig       # Build logic: source fetch, header sync, module export
├── src.zig         # Zig API: error mapping + basic utility wrappers
├── vendor/portaudio/ # (git-ignored) cloned upstream source
└── c_include/      # (git-ignored) copied public headers
```

`vendor/` and `c_include/` are generated at build time and should not be
committed.

## Usage

From this directory:

```bash
zig build test
```

Upstream source is pinned in `build.zig`
(`147dd722548358763a8b649b3e4b41dfffbcfbb6`).
To update version, edit that constant and rebuild.

Pass custom C macro:

```bash
zig build test -Dportaudio_define=PA_ENABLE_DEBUG_OUTPUT=1
```

Host backend selection is automatic by target platform:
- macOS: CoreAudio
- Linux/Windows/other: skeleton backend (compile-safe default)
