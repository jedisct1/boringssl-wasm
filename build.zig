const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;

const path_boringssl = "boringssl";

fn joinPath(alloc: mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, name });
}

fn buildErrData(b: *std.Build, mod: *std.Build.Module) void {
    const go_build = b.addSystemCommand(&.{ "go", "build" });
    go_build.setCwd(b.path(path_boringssl ++ "/util/pregenerate"));

    const pregenerate = b.addSystemCommand(&.{"util/pregenerate/pregenerate"});
    pregenerate.setCwd(b.path(path_boringssl));
    pregenerate.step.dependOn(&go_build.step);
    const generated_file = pregenerate.captureStdOut(.{ .basename = "err_data_generate.c" });

    mod.addCSourceFile(.{ .file = generated_file, .flags = &.{} });
}

fn addDir(b: *std.Build, alloc: mem.Allocator, io: Io, mod: *std.Build.Module, base: []const u8) !void {
    var dir = Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (file.kind == .directory) {
            if (mem.eql(u8, std.fs.path.extension(file.name), "test") or
                mem.eql(u8, std.fs.path.extension(file.name), "asm"))
            {
                continue;
            }
            const sub = try joinPath(alloc, base, file.name);
            defer alloc.free(sub);
            try addDir(b, alloc, io, mod, sub);
        }
        if (file.kind != .file or !mem.eql(u8, std.fs.path.extension(file.name), ".c")) {
            continue;
        }
        const path = try joinPath(alloc, base, file.name);
        defer alloc.free(path);
        mod.addCSourceFile(.{ .file = b.path(path), .flags = &.{} });
    }
}

fn addSubdirs(b: *std.Build, alloc: mem.Allocator, io: Io, mod: *std.Build.Module, base: []const u8) !void {
    var dir = Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (file.kind != .directory) {
            continue;
        }
        const path = try joinPath(alloc, base, file.name);
        defer alloc.free(path);
        try addDir(b, alloc, io, mod, path);
    }
}

pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const io = b.graph.io;

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .wasm32, .os_tag = .wasi } });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
    });

    const lib = b.addLibrary(.{
        .name = "crypto",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    if (optimize == .ReleaseSmall) {
        mod.addCMacro("OPENSSL_SMALL", "");
    }

    mod.addCMacro("ARCH", "generic");
    mod.addCMacro("OPENSSL_NO_ASM", "");

    if (target.result.os.tag == .wasi) {
        mod.addCMacro("OPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_IF_THREADED", "");
        mod.addCMacro("SO_KEEPALIVE", "0");
        mod.addCMacro("SO_ERROR", "0");
        mod.addCMacro("FREEBSD_GETRANDOM", "");
        mod.addCMacro("getrandom(a,b,c)", "getentropy(a,b)|b");
        mod.addCMacro("socket(a,b,c)", "-1");
        mod.addCMacro("setsockopt(a,b,c,d,e)", "-1");
        mod.addCMacro("connect(a,b,c)", "-1");
        mod.addCMacro("GRND_NONBLOCK", "0");
    }

    mod.addIncludePath(b.path(path_boringssl ++ "/include"));
    const base_crypto = path_boringssl ++ "/crypto";
    const base_decrepit = path_boringssl ++ "/decrepit";
    buildErrData(b, mod);
    try addDir(b, gpa.allocator(), io, mod, base_crypto);
    try addDir(b, gpa.allocator(), io, mod, base_decrepit);
    try addSubdirs(b, gpa.allocator(), io, mod, base_crypto);
}
