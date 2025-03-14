const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Compile = std.Build.Step.Compile;

const path_boringssl = "boringssl";

fn withBase(alloc: mem.Allocator, base: []const u8, name: []const u8) !ArrayList(u8) {
    var path = ArrayList(u8).init(alloc);
    try path.appendSlice(base);
    try path.append(fs.path.sep);
    try path.appendSlice(name);
    return path;
}

fn buildErrData(b: *std.Build, alloc: mem.Allocator, lib: *Compile, base: []const u8) !void {
    const out_name = "err_data_generate.c";

    var dir = try fs.cwd().makeOpenPath(base, .{});
    defer dir.close();
    var fd = try dir.createFile(out_name, .{});
    defer fd.close();

    var arena = heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    {
        var child = std.process.Child.init(
            &.{ "go", "build" },
            arena.allocator(),
        );
        child.cwd = path_boringssl ++ "/util/pregenerate";
        child.stdout_behavior = .Pipe;
        try child.spawn();
        _ = try child.wait();
    }
    {
        var child = std.process.Child.init(
            &.{"util/pregenerate/pregenerate"},
            arena.allocator(),
        );
        child.cwd = path_boringssl;
        child.stdout_behavior = .Pipe;
        try child.spawn();
        try fd.writeFileAll(child.stdout.?, .{});
        _ = try child.wait();
    }

    const path = try withBase(alloc, base, out_name);
    defer path.deinit();
    lib.addCSourceFile(.{ .file = b.path(path.items), .flags = &.{} });
}

fn addDir(b: *std.Build, alloc: mem.Allocator, lib: *Compile, base: []const u8) !void {
    var dir = try fs.cwd().openDir(base, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |file| {
        if (file.kind == .directory) {
            if (mem.eql(u8, fs.path.extension(file.name), "test") or
                mem.eql(u8, fs.path.extension(file.name), "asm"))
            {
                continue;
            }
            const path = try withBase(alloc, base, file.name);
            defer path.deinit();
            try addDir(b, alloc, lib, path.items);
        }
        if (file.kind != .file or !mem.eql(u8, fs.path.extension(file.name), ".c")) {
            continue;
        }
        const path = try withBase(alloc, base, file.name);
        defer path.deinit();
        lib.addCSourceFile(.{ .file = b.path(path.items), .flags = &.{} });
    }
}

fn addSubdirs(b: *std.Build, alloc: mem.Allocator, lib: *Compile, base: []const u8) !void {
    var dir = try fs.cwd().openDir(base, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |file| {
        if (file.kind != .directory) {
            continue;
        }
        const path = try withBase(alloc, base, file.name);
        defer path.deinit();
        try addDir(b, alloc, lib, path.items);
    }
}

pub fn build(b: *std.Build) !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .wasm32, .os_tag = .wasi } });

    const lib = b.addStaticLibrary(.{
        .name = "crypto",
        .optimize = optimize,
        .target = target,
        .strip = true,
    });
    lib.linkLibC();
    b.installArtifact(lib);
    if (optimize == .ReleaseSmall) {
        lib.root_module.addCMacro("OPENSSL_SMALL", "");
    }

    lib.root_module.addCMacro("ARCH", "generic");
    lib.root_module.addCMacro("OPENSSL_NO_ASM", "");

    if (target.result.os.tag == .wasi) {
        lib.root_module.addCMacro("OPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_IF_THREADED", "");
        lib.root_module.addCMacro("SO_KEEPALIVE", "0");
        lib.root_module.addCMacro("SO_ERROR", "0");
        lib.root_module.addCMacro("FREEBSD_GETRANDOM", "");
        lib.root_module.addCMacro("getrandom(a,b,c)", "getentropy(a,b)|b");
        lib.root_module.addCMacro("socket(a,b,c)", "-1");
        lib.root_module.addCMacro("setsockopt(a,b,c,d,e)", "-1");
        lib.root_module.addCMacro("connect(a,b,c)", "-1");
        lib.root_module.addCMacro("GRND_NONBLOCK", "0");
    }

    lib.addIncludePath(b.path(path_boringssl ++ fs.path.sep_str ++ "include"));
    const base_crypto = path_boringssl ++ fs.path.sep_str ++ "crypto";
    const base_decrepit = path_boringssl ++ fs.path.sep_str ++ "decrepit";
    const base_generated = "generated";
    try buildErrData(b, gpa.allocator(), lib, base_generated);
    try addDir(b, gpa.allocator(), lib, base_crypto);
    try addDir(b, gpa.allocator(), lib, base_decrepit);
    try addSubdirs(b, gpa.allocator(), lib, base_crypto);
}
