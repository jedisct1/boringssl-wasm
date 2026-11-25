const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const path_boringssl = "boringssl";
const wasm_c_flags: []const []const u8 = &.{ "-std=c23", "-include", "include/wasm_compat.h" };
const cpp_flags: []const []const u8 = &.{"-std=c++17"};
const wasm_cpp_flags: []const []const u8 = &.{ "-std=c++17", "-include", "include/wasm_compat.h" };

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

fn addDir(b: *std.Build, alloc: mem.Allocator, io: Io, mod: *std.Build.Module, base: []const u8, freestanding_wasm: bool) !void {
    b.dependOnDirectoryContents(b.path(base));
    var dir = try b.root.root_dir.handle.openDir(io, base, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (file.kind == .directory) {
            if (isSkippedDir(file.name)) continue;
            // Skip fipsmodule subdirectories — they contain .cc.inc files
            // included by bcm.cc as a unity build
            if (mem.eql(u8, file.name, "fipsmodule")) continue;
            const sub = try joinPath(alloc, base, file.name);
            defer alloc.free(sub);
            try addDir(b, alloc, io, mod, sub, freestanding_wasm);
        }
        if (file.kind != .file) continue;
        const ext = std.fs.path.extension(file.name);
        if (!mem.eql(u8, ext, ".c") and !mem.eql(u8, ext, ".cc")) continue;
        if (isTestFile(file.name)) continue;
        const path = try joinPath(alloc, base, file.name);
        defer alloc.free(path);
        const flags: []const []const u8 = if (mem.eql(u8, ext, ".cc"))
            (if (freestanding_wasm) wasm_cpp_flags else cpp_flags)
        else
            (if (freestanding_wasm) wasm_c_flags else &.{});
        mod.addCSourceFile(.{ .file = b.path(path), .flags = flags });
    }
}

pub fn build(b: *std.Build) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const io = b.graph.io;

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .wasm32, .os_tag = .freestanding } });

    const freestanding_wasm = target.result.cpu.arch.isWasm() and target.result.os.tag == .freestanding;
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = !freestanding_wasm,
        .link_libcpp = !freestanding_wasm,
        .strip = true,
    });

    const lib = b.addLibrary(.{
        .name = "crypto",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    if (optimize == .small) {
        mod.addCMacro("OPENSSL_SMALL", "");
    }

    mod.addCMacro("ARCH", "generic");
    mod.addCMacro("OPENSSL_NO_ASM", "");

    if (freestanding_wasm) {
        const c_headers = b.option([]const u8, "wasm-c-include", "Path to the WASI SDK C headers");
        const cxx_headers = b.option([]const u8, "wasm-cxx-include", "Path to the WASI SDK C++ headers");
        if (c_headers == null or cxx_headers == null) {
            lib.step.dependOn(&b.addFail("provide -Dwasm-c-include and -Dwasm-cxx-include for the freestanding WebAssembly build").step);
            return;
        }

        const minilibc = b.lazyDependency("minilibc", .{}) orelse return;
        const libc_module = b.createModule(.{ .target = target, .optimize = optimize });
        libc_module.addIncludePath(minilibc.path("include"));
        libc_module.addCSourceFile(.{ .file = minilibc.path("src/libc.c") });
        const libc = b.addObject(.{ .name = "minilibc", .root_module = libc_module });
        mod.addObject(libc);
        mod.addIncludePath(.{ .cwd_relative = cxx_headers.? });
        mod.addSystemIncludePath(.{ .cwd_relative = c_headers.? });
        mod.addCMacro("__wasi__", "1");
        mod.addCMacro("OPENSSL_NO_SOCK", "1");
        mod.addCMacro("OPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_IF_THREADED", "1");
    }

    mod.addIncludePath(b.path(path_boringssl ++ "/include"));

    const base_crypto = path_boringssl ++ "/crypto";
    const base_decrepit = path_boringssl ++ "/decrepit";

    // Add all crypto and decrepit sources (recursive)
    try addDir(b, gpa.allocator(), io, mod, base_crypto, freestanding_wasm);
    try addDir(b, gpa.allocator(), io, mod, base_decrepit, freestanding_wasm);

    mod.addCSourceFile(.{ .file = b.path(base_crypto ++ "/fipsmodule/bcm.c"), .flags = if (freestanding_wasm) wasm_c_flags else &.{} });
    mod.addCSourceFile(.{ .file = b.path(base_crypto ++ "/fipsmodule/fips_shared_support.c"), .flags = if (freestanding_wasm) wasm_c_flags else &.{} });

    mod.addCSourceFile(.{ .file = b.path(path_boringssl ++ "/gen/crypto/err_data.c"), .flags = if (freestanding_wasm) wasm_c_flags else &.{} });
}
