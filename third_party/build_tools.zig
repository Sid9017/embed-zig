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

pub const ExternalStaticLibraryModule = struct {
    module: *std.Build.Module,
    lib: *std.Build.Step.Compile,
    repo: Repo,
};

pub const ExternalStaticLibraryModuleConfig = struct {
    c_repo_src: RepoSrc,
    library: std.Build.LibraryOptions,
    module: std.Build.Module.CreateOptions,
    include_dirs: []const []const u8 = &.{},
    user_define_option: ?UserDefineOptions = null,
    c_sources: []const []const u8 = &.{},
    c_flags: []const []const u8 = &.{},
    command: []const []const u8 = &.{},
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

pub fn addStaticLibraryModule(
    b: *std.Build,
    name: []const u8,
    config: ExternalStaticLibraryModuleConfig,
) ExternalStaticLibraryModule {
    const repo = downloadSource(b, config.c_repo_src);
    const user_define = if (config.user_define_option) |opt|
        b.option([]const u8, opt.name, opt.description)
    else
        null;
    const macro_defines: []const MacroDefine = if (config.user_define_option) |opt|
        opt.macro_defines
    else
        &.{};

    const lib = b.addLibrary(config.library);
    for (config.include_dirs) |dir| {
        lib.addIncludePath(repo.includePath(b, dir));
    }
    for (config.c_sources) |src| {
        lib.addCSourceFile(.{
            .file = repo.sourcePath(b, src),
            .flags = config.c_flags,
        });
    }
    for (macro_defines) |define| {
        lib.root_module.addCMacro(define.name, define.value);
    }
    applyUserDefine(lib.root_module, user_define);

    var ensure_step = repo.ensure_step;
    if (config.command.len != 0) {
        const command = b.addSystemCommand(config.command);
        command.setEnvironmentVariable("TP_SOURCE_ROOT", repo.source_root_path);
        command.setEnvironmentVariable("TP_PREFIX_ROOT", repo.prefix_path);
        command.step.dependOn(ensure_step);
        ensure_step = &command.step;
    }
    lib.step.dependOn(ensure_step);

    const module = b.addModule(name, config.module);
    for (config.include_dirs) |dir| {
        module.addIncludePath(repo.includePath(b, dir));
    }
    for (macro_defines) |define| {
        module.addCMacro(define.name, define.value);
    }
    applyUserDefine(module, user_define);

    return .{
        .module = module,
        .lib = lib,
        .repo = .{
            .ensure_step = ensure_step,
            .prefix_path = repo.prefix_path,
            .source_root_path = repo.source_root_path,
            .repo_key = repo.repo_key,
            .commit_key = repo.commit_key,
        },
    };
}

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
                    "git -C '{s}' fetch --depth 1 origin '{s}'; " ++
                    "git -C '{s}' checkout --detach FETCH_HEAD",
                .{ source_root_path, commit, source_root_path },
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
