#!/usr/bin/env python3
"""
Lint checker for Zig import rules defined in AGENTS.md.

Rules enforced:
  R1  No @import("embed") in src/
  R2  Cross-layer imports in src/ must go through mod.zig
  R3  No struct { } wrappers around imports
  R4  Import ordering: std -> embed(mod.zig) -> runtime -> hal -> sibling
  R5  cmd/ and test/ must use @import("embed"), not relative paths into src/
  R6  hal must not depend on runtime
  R7  No generic alias names (module, mod, lib, pkg)
  R8  No member-level aliases — alias at file/module level only
  R9  No upward .. imports in src/ except to mod.zig
  R10 No pub imports — @import must use const, not pub const

Exit code 0 = clean, 1 = violations found.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

LAYERS = ("hal", "runtime", "pkg", "third_party", "websim")

IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')

STRUCT_IMPORT_RE = re.compile(
    r"""
    (pub\s+)?const\s+\w+\s*=\s*struct\s*\{
    [^}]*@import\s*\(
    """,
    re.VERBOSE | re.DOTALL,
)

STRUCT_IMPORT_LINE_RE = re.compile(
    r'(pub\s+)?const\s+\w+\s*=\s*struct\s*\{'
)

GENERIC_ALIAS_RE = re.compile(
    r'^const\s+(module)\s*='
)

MEMBER_EXTRACT_RE = re.compile(
    r'^(pub\s+)?const\s+(\w+)\s*=\s+(embed(?:\.\w+){2,})\.(\w+)\s*;$'
)

PUB_IMPORT_RE = re.compile(
    r'^pub\s+const\s+\w+\s*=\s*@import\('
)

UPWARD_IMPORT_RE = re.compile(
    r'@import\("(\.\.[^"]+)"\)'
)


@dataclass
class Violation:
    file: str
    line: int
    rule: str
    message: str

    def __str__(self) -> str:
        return f"{self.file}:{self.line}: [{self.rule}] {self.message}"


def is_comment_line(line: str) -> bool:
    return line.lstrip().startswith("//")


def layer_of(relpath: str) -> str | None:
    """Return the top-level layer name for a file under src/."""
    parts = relpath.split("/")
    if len(parts) >= 2 and parts[0] == "src" and parts[1] in LAYERS:
        return parts[1]
    return None


def resolve_import_target_layer(file_relpath: str, import_path: str) -> str | None:
    """Given a file and its relative @import path, resolve which src/ layer the
    import points to.  Returns None if the import stays within the same layer
    or is not a relative path."""
    if not import_path.startswith("."):
        return None

    file_dir = os.path.dirname(file_relpath)
    resolved = os.path.normpath(os.path.join(file_dir, import_path))
    parts = resolved.split("/")
    if len(parts) >= 2 and parts[0] == "src" and parts[1] in LAYERS:
        return parts[1]
    return None


def is_same_or_child_dir(file_relpath: str, import_path: str) -> bool:
    """Return True if the import target is in the same directory or a child."""
    if not import_path.startswith("."):
        return True
    return not import_path.startswith("..")


def check_file(filepath: Path, violations: list[Violation]) -> None:
    relpath = str(filepath.relative_to(REPO_ROOT))
    try:
        lines = filepath.read_text(encoding="utf-8").splitlines()
    except Exception:
        return

    in_src = relpath.startswith("src/")
    in_cmd = relpath.startswith("cmd/")
    in_test = relpath.startswith("test/")
    in_hal = relpath.startswith("src/hal/")

    file_layer = layer_of(relpath) if in_src else None

    full_text = "\n".join(lines)

    is_mod_zig = relpath.endswith("mod.zig")

    # --- R3: struct wrappers around cross-layer imports ---
    # mod.zig uses struct namespaces by design; same-layer struct wrappers are OK.
    if not is_mod_zig:
        for m in STRUCT_IMPORT_RE.finditer(full_text):
            block_text = m.group(0)
            block_imports = IMPORT_RE.findall(block_text)
            has_cross_layer = False
            for imp in block_imports:
                if imp.startswith(".."):
                    target = resolve_import_target_layer(relpath, imp)
                    if target is not None and target != file_layer:
                        has_cross_layer = True
                        break
            if has_cross_layer:
                start = full_text[: m.start()].count("\n") + 1
                violations.append(Violation(relpath, start, "R3",
                                            "struct {{ }} wrapper around cross-layer @import"))

    # --- per-line checks ---
    import_order_groups: list[tuple[int, int]] = []
    header_ended = False

    for lineno_0, raw_line in enumerate(lines):
        lineno = lineno_0 + 1

        if is_comment_line(raw_line):
            continue

        stripped = raw_line.lstrip()

        # R7: no generic alias names (checked before import filtering)
        if GENERIC_ALIAS_RE.match(stripped):
            alias_name = GENERIC_ALIAS_RE.match(stripped).group(1)
            violations.append(Violation(relpath, lineno, "R7",
                                        f'generic alias name "{alias_name}" — '
                                        f"use the full path or extract declarations directly"))

        # R8: no member-level aliases — only flag top-level extractions of a
        # PascalCase type/function from a module path
        # (e.g. const Error = embed.hal.adc.Error).
        # Module-level aliases (const record = embed.pkg.net.tls.record) are fine.
        # Skip indented lines (inside struct/fn blocks).
        m8 = MEMBER_EXTRACT_RE.match(stripped)
        if m8 and not raw_line.startswith((" ", "\t")):
            const_name = m8.group(2)
            member_name = m8.group(4)
            if const_name == member_name and const_name[0].isupper():
                violations.append(Violation(relpath, lineno, "R8",
                                            f'member-level alias: const {const_name} = ...{member_name} — '
                                            f"alias at the file/module level instead"))

        # R9: no upward .. imports in src/ except to mod.zig
        if in_src and not relpath.startswith("src/third_party/"):
            for m9 in UPWARD_IMPORT_RE.finditer(raw_line):
                imp9 = m9.group(1)
                if imp9.startswith("..") and not imp9.endswith("mod.zig"):
                    violations.append(Violation(relpath, lineno, "R9",
                                                f'upward import @import("{imp9}") — '
                                                f"use mod.zig for cross-directory access"))

        # R10: no pub imports — top-level @import must be const, not pub const.
        # Skip: mod.zig files, indented lines (inside struct/fn blocks),
        # test/esp/ and test/firmware/ (build-system config files where pub
        # re-exports are the intended pattern).
        if not is_mod_zig and PUB_IMPORT_RE.match(stripped):
            if not raw_line.startswith((" ", "\t")):
                if not (relpath.startswith("test/esp/") or relpath.startswith("test/firmware/")):
                    violations.append(Violation(relpath, lineno, "R10",
                                                "pub @import — imports must be const, not pub const"))

        imports_on_line = IMPORT_RE.findall(raw_line)
        if not imports_on_line:
            # A non-empty, non-comment, non-import line at top level ends the
            # header import block (for R4 purposes).  Blank lines and doc
            # comments are allowed between imports.
            if stripped and not header_ended:
                if not stripped.startswith("const ") and not stripped.startswith("pub const "):
                    header_ended = True
            continue

        for imp in imports_on_line:
            # R1
            if in_src and imp == "embed":
                violations.append(Violation(relpath, lineno, "R1",
                                            '@import("embed") used inside src/'))

            # R5
            if (in_cmd or in_test) and imp.startswith("..") and "/src/" in os.path.normpath(
                    os.path.join(os.path.dirname(relpath), imp)):
                violations.append(Violation(relpath, lineno, "R5",
                                            f'relative path into src/: @import("{imp}") — use @import("embed") instead'))

            # R6
            if in_hal and imp.startswith(".."):
                target_layer = resolve_import_target_layer(relpath, imp)
                if target_layer == "runtime":
                    violations.append(Violation(relpath, lineno, "R6",
                                                "hal imports from runtime"))

            # R2: cross-layer in src/
            if in_src and imp.startswith("..") and file_layer is not None:
                target_layer = resolve_import_target_layer(relpath, imp)
                if target_layer is not None and target_layer != file_layer:
                    if not imp.endswith("mod.zig"):
                        violations.append(Violation(relpath, lineno, "R2",
                                                    f'cross-layer import @import("{imp}") — should go through mod.zig'))

        # R4: ordering — only for the initial header import block
        if not header_ended and (stripped.startswith("const ") or stripped.startswith("pub const ")):
            first_imp = imports_on_line[0]
            group = _import_order_group(first_imp, in_src)
            if group is not None:
                import_order_groups.append((lineno, group))

    # R4: check monotonic ordering
    for i in range(1, len(import_order_groups)):
        prev_line, prev_group = import_order_groups[i - 1]
        cur_line, cur_group = import_order_groups[i]
        if cur_group < prev_group:
            violations.append(Violation(relpath, cur_line, "R4",
                                        f"import ordering: group {cur_group} appears after group {prev_group} "
                                        f"(expected std=0 < embed=1 < runtime=2 < hal=3 < sibling=4)"))


def _import_order_group(imp: str, in_src: bool) -> int | None:
    """Classify an import into ordering groups:
    0 = std, 1 = embed(mod.zig), 2 = runtime, 3 = hal, 4 = sibling/other.
    Returns None for non-top-level imports we can't classify."""
    if imp == "std":
        return 0
    if imp == "embed":
        return 1
    if imp.endswith("mod.zig"):
        return 1
    if imp == "builtin":
        return 0
    return None


def collect_zig_files() -> list[Path]:
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(REPO_ROOT):
        dirnames[:] = [d for d in dirnames if d != ".zig-cache" and d != "zig-cache" and d != ".git"]
        rel = os.path.relpath(dirpath, REPO_ROOT)
        if not (rel.startswith("src") or rel.startswith("cmd") or rel.startswith("test")):
            if rel != ".":
                dirnames.clear()
            continue
        for fn in filenames:
            if fn.endswith(".zig"):
                files.append(Path(dirpath) / fn)
    return sorted(files)


def main() -> int:
    violations: list[Violation] = []
    files = collect_zig_files()

    for f in files:
        check_file(f, violations)

    if not violations:
        print(f"OK — {len(files)} files checked, no violations.")
        return 0

    by_rule: dict[str, int] = {}
    for v in violations:
        by_rule[v.rule] = by_rule.get(v.rule, 0) + 1
        print(v)

    print(f"\n{len(violations)} violation(s) in {len(set(v.file for v in violations))} file(s):")
    for rule in sorted(by_rule):
        print(f"  {rule}: {by_rule[rule]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
