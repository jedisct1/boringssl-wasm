# BoringSSL (boringcrypto) for WebAssembly

A Zig build file to compile BoringSSL's `libcrypto` to WebAssembly.

## Precompiled library

For convenience, a [precompiled library](precompiled/libcrypto.a) for WebAssembly can be directly downloaded from this repository.

## Dependencies

* [Go](https://www.golang.org) - Required by BoringSSL to generate the error codes map
* [Zig](https://ziglang.org) to compile C and C++ code to WebAssembly
* WASI SDK C and C++ headers to compile the freestanding target

## BoringSSL submodule

This repository includes an unmodified version of `BoringSSL` as a submodule. If you didn't clone it with the `--recursive` flag, the following command can be used to pull the submodule:

```sh
git submodule update --init --recursive --depth=1
```

## Building the BoringSSL crypto library for WebAssembly

The build targets `wasm32-freestanding` and includes `wasm-minilibc`.
Pass the directories containing the WASI SDK C and C++ headers.

```sh
zig build -Doptimize=fast \
  -Dwasm-c-include=/path/to/wasi-c-headers \
  -Dwasm-cxx-include=/path/to/wasi-cxx-headers
```

The resulting static library is put into `zig-out/lib/libcrypto.a`.

Build modes:

* `-Doptimize=fast`
* `-Doptimize=safe`
* `-Doptimize=small` (also turns `OPENSSL_SMALL` on to disable precomputed tables)
* `-Doptimize=debug` (default, not recommended in production builds)

The library is compatible with the vast majority of WebAssembly runtimes, and can be used linked with C, Zig, Rust, whatever.

Add `-Dcpu=baseline+simd128+multivalue+bulk_memory` to enable those WebAssembly features.

Possibly relevant extensions:

* `bulk_memory`
* `exception_handling`
* `multivalue`
* `sign_ext`
* `simd128`
* `tail_call`

## Cross-compiling to other targets

The build file can be used to cross-compile to other targets as well. However, assembly implementations will not be included.

### Examples

Compile to the native architecture:

```sh
zig build -Dtarget=native -Doptimize=fast
```

Cross-compile to `x86_64-linux`:

```sh
zig build -Dtarget=x86_64-linux -Doptimize=small
```

Cross-compile to Apple Silicon:

```sh
zig build -Dtarget=aarch64-macos -Doptimize=safe
```
