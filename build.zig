const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;

const path_boringssl = "boringssl";
const cpp_flags: []const []const u8 = &.{"-std=c++17"};

fn joinPath(alloc: mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, name });
}

fn isSkippedDir(name: []const u8) bool {
    const skipped = [_][]const u8{ "test", "asm", "perlasm" };
    for (skipped) |s| {
        if (mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn isTestFile(name: []const u8) bool {
    const stem = std.fs.path.stem(name);
    return mem.endsWith(u8, stem, "_test");
}

fn addDir(b: *std.Build, alloc: mem.Allocator, io: Io, mod: *std.Build.Module, base: []const u8, recurse: bool) !void {
    var dir = Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (file.kind == .directory and recurse) {
            if (isSkippedDir(file.name)) continue;
            // Skip fipsmodule subdirectories — they contain .cc.inc files
            // included by bcm.cc as a unity build
            if (mem.eql(u8, file.name, "fipsmodule")) continue;
            const sub = try joinPath(alloc, base, file.name);
            defer alloc.free(sub);
            try addDir(b, alloc, io, mod, sub, true);
        }
        if (file.kind != .file) continue;
        const ext = std.fs.path.extension(file.name);
        if (!mem.eql(u8, ext, ".c") and !mem.eql(u8, ext, ".cc")) continue;
        if (isTestFile(file.name)) continue;
        const path = try joinPath(alloc, base, file.name);
        defer alloc.free(path);
        const flags: []const []const u8 = if (mem.eql(u8, ext, ".cc")) cpp_flags else &.{};
        mod.addCSourceFile(.{ .file = b.path(path), .flags = flags });
    }
}

pub fn build(b: *std.Build) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const io = b.graph.io;

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .wasm32, .os_tag = .wasi } });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
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

    // Add all crypto and decrepit sources (recursive)
    try addDir(b, gpa.allocator(), io, mod, base_crypto, true);
    try addDir(b, gpa.allocator(), io, mod, base_decrepit, true);

    mod.addCSourceFile(.{ .file = b.path(base_crypto ++ "/fipsmodule/bcm.c"), .flags = &.{} });
    mod.addCSourceFile(.{ .file = b.path(base_crypto ++ "/fipsmodule/fips_shared_support.c"), .flags = &.{} });

    mod.addCSourceFile(.{ .file = b.path(path_boringssl ++ "/gen/crypto/err_data.c"), .flags = &.{} });
}
