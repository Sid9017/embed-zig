# AGENTS.md

Guidance for coding agents working in this repository. The goal is to help agents understand the current directory structure, build flow, architectural boundaries, and testing expectations, while preserving cross-platform abstractions and behavioral consistency.

## TOC

- [Repository Overview](#repository-overview)
- [Directory Structure](#directory-structure)
- [Build And Test Commands](#build-and-test-commands)
- [Code Style And Architectural Constraints](#code-style-and-architectural-constraints)
- [Testing Expectations For Agents](#testing-expectations-for-agents)
- [Commit And Documentation Sync](#commit-and-documentation-sync)
- [Pre-Handoff Checklist](#pre-handoff-checklist)
- [Quick Commands](#quick-commands)

## Repository Overview

- Language: Zig, with `0.15.x` as the main local environment
- Package name: `embed_zig`
- Default exported module name: `embed`
- The repository root has a shared `build.zig`
- The top-level export file is `src/mod.zig`, not `src/root.zig`

Project positioning:

- `embed-zig` uses `comptime` to compose `hal` and `runtime` adaptation layers for different hardware platforms and host environments
- Target platforms include ESP, BK, and host environments
- It provides cross-platform capabilities such as an event bus, app stage management, flux/reducer, UI rendering, audio processing, BLE, networking, and async execution
- The intended workflow is: develop firmware or app logic -> validate in `websim` -> adapt to multiple hardware targets -> release
- This repository is also designed for Agentic Coding workflows, emphasizing fast development, fast verification, and fast testing

## Directory Structure

- `src/mod.zig`: top-level export entrypoint
- `src/runtime/`: runtime abstractions and standard implementations
- `src/hal/`: HAL abstractions
- `src/pkg/`: higher-level cross-platform modules
- `src/websim/`: web simulation, remote HAL, and test runner
- `src/third_party/`: third-party libraries and font assets
- `cmd/audio_engine/`: host-side audio example
- `cmd/bleterm/`: host-side BLE terminal tool
- `test/firmware/`: platform-agnostic firmware/app test assets
- `test/websim/`: test cases built around `websim`
- `test/esp/`: ESP platform adaptation and build examples

What agents should assume about the structure:

- Exported entrypoints are centralized in `src/mod.zig`
- Platform differences should be pushed down into `hal` / `runtime` adaptation layers whenever possible
- Cross-platform logic should generally live in `pkg`
- If a change affects test examples or platform-specific directories, also check `test/websim/` and `test/esp/`

## Build And Test Commands

### Format

```bash
zig fmt src/**/*.zig cmd/**/*.zig test/**/*.zig
```

If your shell does not expand `**`, use explicit file paths instead.

### Baseline

- There is no dedicated linter
- The minimum validation baseline is `zig fmt` plus relevant `zig build test`

### Root build

The root `build.zig` only builds the library and does **not** contain test steps. Use it for:

```bash
zig build                # build the library
```

### Unit tests

All tests live under `test/unit/`. This directory is a standalone Zig project with its own `build.zig` and `build.zig.zon` that depends on the root `embed_zig` package.

- `test/unit/mod.zig` is the test entrypoint — it imports every `*_test.zig` file
- `test/unit/build.zig` creates the test executable and links required third-party libraries

Run all unit tests:

```bash
zig build test
```

Run with a filter:

```bash
zig build test -- --test-filter "socket tcp loopback echo"
```

Both commands must be run from the `test/unit/` directory.

### Test file location

- There are **no** test files inside `src/`; all `*_test.zig` files live under `test/unit/`
- Test files mirror the `src/` directory structure: `src/pkg/audio/mixer.zig` → `test/unit/pkg/audio/mixer_test.zig`
- When adding a new test file, also add its `@import` to `test/unit/mod.zig`

### Example apps

Run host-side example apps from their own directories:

```bash
zig build run
```

## Code Style And Architectural Constraints

### Imports

#### Ordering

Imports must appear at the top of the file in this order:

1. `const std = @import("std");`
2. `const embed = @import("embed");` — external module, only in `cmd/` and `test/`; never in `src/`
3. Runtime imports — `runtime_suite`, contract utility modules (`thread_mod`, `socket_mod`, …)
4. HAL imports — `gpio_mod`, `adc_mod`, …
5. Same-package sibling imports — `const record = @import("record.zig");`

#### Style

- All imports are flat `const x = @import(...)` — **no `struct { }` wrappers**
- **Never `pub` an import** — imports must always be `const`, never `pub const`. Re-exporting an import lets other modules reach into a sibling's dependencies, creating implicit coupling. If another file needs a symbol, it should import the source directly rather than going through an intermediary. The only exception is `mod.zig` entrypoint files whose explicit purpose is re-exporting a package's public surface.
- Remove unused imports

#### Cross-layer imports — use `mod.zig`, not relative paths

Direct `@import` of a `.zig` file is only allowed for **same directory or child directories**. When importing from a parent or sibling layer (e.g., `pkg` → `runtime`, `pkg` → `hal`), always go through `mod.zig`:

```zig
// Bad — relative path climbing up to another layer
const runtime_suite = @import("../../../runtime/runtime.zig");
const socket_mod = @import("../../../runtime/socket.zig");
const hal = struct {
    pub const gpio = @import("../../../../hal/gpio.zig");
};

// Good — go through mod.zig, name it `embed` (same as cmd/test)
const embed = @import("../../../mod.zig");
// then use embed.runtime.Make, embed.runtime.socket.parseIpv4, embed.hal.gpio, etc.
```

- `src/` files: `const embed = @import("<relative-path>/mod.zig");`
- `cmd/` and `test/` files: `const embed = @import("embed");`

Both use the name `embed` so that cross-layer access reads identically everywhere:
`embed.runtime.*`, `embed.hal.*`, `embed.pkg.*`.

Same-directory and child imports remain direct:

```zig
const record = @import("record.zig");
const handshake = @import("handshake.zig");
```

#### Naming

- `_mod` suffix for module imports that expose multiple declarations: `const mixer_mod = @import("mixer.zig");`
- No suffix when the import is single-purpose or re-exports a primary type: `const record = @import("record.zig");`
- `runtime_suite` specifically for `@import("runtime/runtime.zig")` (the sealed runtime contract)
- **No generic alias names** — names like `module`, `mod`, `lib`, or `pkg` carry no meaning
- **No member-level aliases** — do not extract individual types or functions into top-level `const`. Alias only at the file/module level, then access members through the alias:

```zig
// Bad — generic alias + member extraction
const module = @import("embed").hal.adc;
const Error = module.Error;
const from = module.from;

// Bad — member extraction even with full path
const embed = @import("embed");
const Error = embed.hal.adc.Error;
const from = embed.hal.adc.from;

// Good — alias at the file/module level, access members through it
const embed = @import("embed");
const adc = embed.hal.adc;
// then use adc.Error, adc.from, adc.Config, etc.

// Good — for test files, PascalCase alias for the module under test
const embed = @import("embed");
const Display = embed.hal.display;
// then use Display.is, Display.from, Display.Error, etc.
```

#### Aliasing

1. Prefer **no alias** — use the full path directly when usage count is low
2. When an alias is needed, keep the chain **as short as possible** — one alias, not a ladder
3. Alias names should be **short and lowercase-ish** — `Std` not `StdRuntime`, because `StdRuntime` is longer than `runtime.std` and defeats the purpose

```zig
// Best — no alias at all, use inline
const embed = @import("embed");
// ...
fn init() void {
    var m = embed.runtime.std.Mutex.init();
    embed.runtime.std.Log.info("started");
}

// OK — one alias when a path is used many times in the file
const embed = @import("embed");
const Std = embed.runtime.std;
// ...
fn init() void {
    var m = Std.Mutex.init();
    Std.Log.info("started");
}

// Bad — alias chain, each step adds a name but no clarity
const embed = @import("embed");
const runtime = embed.runtime;
const StdRuntime = runtime.std;

// Bad — alias name is longer than the path it replaces
const StdRuntime = embed.runtime.std;  // "StdRuntime" > "runtime.std"
```

#### `src/` vs `cmd/` and `test/`

- Files under `src/` use relative paths to `mod.zig` for cross-layer access; they must **never** `@import("embed")`
- Files under `cmd/` and `test/` import through the package module: `const embed = @import("embed");`

### Formatting

- Always run `zig fmt` before handoff
- Keep files organized by domain and avoid mixing unrelated responsibilities

### File and module organization

- The top-level export entrypoint is `src/mod.zig`
- Runtime standard implementations mainly live under `src/runtime/std*`
- Higher-level cross-platform capabilities mainly live under `src/pkg/`
- `websim` logic lives under `src/websim/`
- Keep algorithm tests close to their implementation files when practical

### Documentation and comments (open-source style)

- **All comments must be in English.** Treat the codebase as an open-source project: write clear, self-contained comments for anyone reading the code later.
- Document all public APIs: every exported struct, function, enum, and field should have a brief comment explaining purpose, contract, and (where relevant) valid values or error conditions.
- Prefer doc comments (`///` or `//`) above declarations; use inline comments for non-obvious logic only.

### Naming

- File names: lowercase snake_case
- Public types: PascalCase
- Functions and methods: lowerCamelCase
- Test names: describe behavior, not implementation details

### Types

- Use exact types in contract surfaces, such as `u32`, `u64`, `[]const u8`, and `bool`
- Avoid vague substitute types in public contracts
- Prefer named types for semantically meaningful grouped values

### Contract checks

- Required functions must use exact signature checks: `@as(*const fn(...), &Impl.method)`
- Do not rely on `@hasDecl` alone for required interfaces
- Optional modules should use `@hasDecl` plus strict `from(...)` validation
- Keep the profile model aligned with `minimal` / `threaded` / `evented`

### Layer boundaries

- `hal` must not depend on `runtime`
- `runtime` may depend on `hal` contracts
- `pkg` may depend on both `hal` and `runtime`
- When adding platform-specific logic, first decide whether it belongs in the adaptation layer or in an upper-level module

### Error handling

- Do not silently swallow critical errors
- Do not hide real failures behind sentinel values
- Map platform errors explicitly into contract-level errors
- Avoid unnecessary `anyerror` in stable APIs

### Runtime conventions

- Keep the IO contract unified: `registerRead/registerWrite/unregister/poll/wake`
- The wake path must support non-blocking behavior and robust draining
- Socket error sets should match real capabilities
- `runtime/ota_backend.zig` should remain a trait-level definition, with orchestration above runtime

## Testing Expectations For Agents

For every change, cover at least:
1. direct tests for the modified file (the corresponding `test/unit/**/*_test.zig`)
2. a full `zig build test` run from `test/unit/`

- When changing crypto-related code:
  - add or update test vectors in the relevant test file
  - cover both positive and negative behavior when practical
- When adding a new source file that needs test coverage, create a matching `*_test.zig` under `test/unit/` and add its `@import` to `test/unit/mod.zig`
- If docs reference directories, module names, commands, or workflow behavior that changed, update them too

## Commit And Documentation Sync

- Keep commits scoped to a single intent
- Do not commit placeholder implementations or TODO stubs
- When changing contracts, directory structure, build commands, or workflow, update both `README.md` and this file
- Do not assume platform integration is identical across targets, especially between host environments and `esp-zig`

## Pre-Handoff Checklist

- [ ] `zig fmt` has been run
- [ ] Relevant tests or build steps have been run
- [ ] Strict contract checks still hold
- [ ] No silent failures or temporary stub code were introduced
- [ ] Documentation is in sync with the current directory structure and commands

## Quick Commands

```bash
# format
zig fmt src/**/*.zig cmd/**/*.zig test/**/*.zig

# run all unit tests (from test/unit/)
cd test/unit && zig build test

# run filtered tests (from test/unit/)
cd test/unit && zig build test -- --test-filter "socket tcp loopback echo"

# build the library (from repo root)
zig build
```
