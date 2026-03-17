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
- The minimum validation baseline is `zig fmt` plus relevant `zig test` / `zig build test`

### Root build

Common commands from the repository root:

```bash
zig build test
zig build test-runtime-std
zig build test-async
zig build test-audio
zig build test-net
zig build test-ble
zig build test-ui
zig build test-event
zig build test-app
```

### Single file tests

```bash
zig test src/mod_test.zig
zig test src/runtime/std_test.zig
zig test src/runtime/io.zig
zig test src/hal/wifi_test.zig
zig test src/pkg/audio/resampler_test.zig
```

### Filtered tests

```bash
zig test src/runtime/std_test.zig --test-filter "socket tcp loopback echo"
zig test src/runtime/std/crypto/hkdf_test.zig --test-filter "RFC5869"
```

### Example apps

Run host-side example apps from their own directories:

```bash
zig build run
```

## Code Style And Architectural Constraints

### Imports

- Put `const std = @import("std");` first when used
- Import local modules after that
- Remove unused imports

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
1. direct tests for the modified file
2. an affected aggregate test or build step
3. one top-level compile or integration check

- When changing `runtime/std`, always run `zig test src/runtime/std_test.zig`
- When changing crypto-related code:
  - add or update test vectors in the relevant algorithm file
  - cover both positive and negative behavior when practical
- If a contract file reports `0 tests passed`, still run `zig test` on it
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
zig build test
zig build test-audio
zig build test-ble
zig test src/mod_test.zig
zig test src/runtime/std_test.zig
zig test src/runtime/std_test.zig --test-filter "io wake drains buffered wake bytes"
```
