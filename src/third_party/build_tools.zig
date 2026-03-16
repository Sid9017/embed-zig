const std = @import("std");

pub const MacroDefine = struct {
    name: []const u8,
    value: []const u8 = "1",
};

pub const UserDefineOptions = struct {
    name: []const u8,
    description: []const u8,
    macro_defines: []const MacroDefine = &.{},
};

pub const default_cache_namespace = "embed-zig-third-party";

pub const RepoSrc = struct {
    git_repo: []const u8,
    commit: ?[]const u8 = null,
    cache_namespace: []const u8 = default_cache_namespace,
};

pub const Repo = struct {
    ensure_step: *std.Build.Step,
    prefix_path: []const u8,
    source_root_path: []const u8,
    repo_key: []const u8,
    commit_key: []const u8,

    pub fn path(self: @This(), b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
        return .{ .cwd_relative = std.fs.path.join(b.allocator, &.{ self.prefix_path, sub_path }) catch @panic("OOM") };
    }

    pub fn sourcePath(self: @This(), b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
        return .{ .cwd_relative = std.fs.path.join(b.allocator, &.{ self.source_root_path, sub_path }) catch @panic("OOM") };
    }

    pub fn includePath(self: @This(), b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
        return .{ .cwd_relative = std.fs.path.join(b.allocator, &.{ self.source_root_path, sub_path }) catch @panic("OOM") };
    }

    pub fn dependOn(self: @This(), step: *std.Build.Step) void {
        step.dependOn(self.ensure_step);
    }
};

pub fn downloadSource(b: *std.Build, config: RepoSrc) Repo {
    const normalized_repo = normalizeGitRepo(b, config.git_repo);
    const commit_key = config.commit orelse "head";
    const prefix_path = b.cache_root.join(b.allocator, &.{
        config.cache_namespace,
        normalized_repo,
        commit_key,
    }) catch @panic("OOM");
    const source_root_path = prefix_path;

    const clone = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        b.fmt(
            "set -eu; " ++
                "if [ ! -d '{s}/.git' ]; then " ++
                "  mkdir -p \"$(dirname '{s}')\"; " ++
                "  git clone --depth 1 '{s}' '{s}'; " ++
                "fi",
            .{ source_root_path, source_root_path, config.git_repo, source_root_path },
        ),
    });

    var ensure_step: *std.Build.Step = &clone.step;
    if (config.commit) |commit| {
        const checkout = b.addSystemCommand(&.{
            "/bin/sh",
            "-c",
            b.fmt(
                "set -eu; " ++
                    "current=$(git -C '{s}' rev-parse HEAD 2>/dev/null || echo none); " ++
                    "if [ \"$current\" != '{s}' ]; then " ++
                    "  git -C '{s}' fetch --depth 1 origin '{s}'; " ++
                    "  git -C '{s}' checkout --detach FETCH_HEAD; " ++
                    "fi",
                .{ source_root_path, commit, source_root_path, commit, source_root_path },
            ),
        });
        checkout.step.dependOn(ensure_step);
        ensure_step = &checkout.step;
    }

    return .{
        .ensure_step = ensure_step,
        .prefix_path = prefix_path,
        .source_root_path = source_root_path,
        .repo_key = normalized_repo,
        .commit_key = commit_key,
    };
}

fn normalizeGitRepo(b: *std.Build, git_repo: []const u8) []const u8 {
    var repo = git_repo;
    if (std.mem.startsWith(u8, repo, "https://")) {
        repo = repo["https://".len..];
    } else if (std.mem.startsWith(u8, repo, "http://")) {
        repo = repo["http://".len..];
    } else if (std.mem.startsWith(u8, repo, "ssh://")) {
        repo = repo["ssh://".len..];
    } else if (std.mem.startsWith(u8, repo, "git@")) {
        repo = repo["git@".len..];
        if (std.mem.indexOfScalar(u8, repo, ':')) |idx| {
            repo = b.fmt("{s}/{s}", .{ repo[0..idx], repo[idx + 1 ..] });
        }
    }
    if (std.mem.endsWith(u8, repo, ".git")) {
        repo = repo[0 .. repo.len - ".git".len];
    }
    return repo;
}

pub fn applyUserDefine(module: *std.Build.Module, define: ?[]const u8) void {
    if (define) |raw| {
        if (raw.len == 0) return;
        if (std.mem.indexOfScalar(u8, raw, '=')) |idx| {
            module.addCMacro(raw[0..idx], raw[idx + 1 ..]);
        } else {
            module.addCMacro(raw, "1");
        }
    }
}
