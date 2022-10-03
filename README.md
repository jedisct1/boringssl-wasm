# BoringSSL (boringcrypto) for WebAssembly

A zig build file to compile BoringSSL's `libcrypto` to WebAssembly/WASI.

## Precompiled library

For convenience, a [precompiled library](precompiled/libcrypto.a) for WebAssembly can be directly downloaded from this repository.

## Dependencies

The only required dependencies to rebuild the library are:

* [Go](https://www.golang.org) - Required by BoringSSL to generate the error codes map
* [Zig](https://www.ziglang.org) - To compile C/C++ code to WebAssembly

## BoringSSL submodule

This repository includes an unmodified version of `BoringSSL` as a submodule. If you didn't clone it with the `--recursive` flag, the following command can be used to pull the submodule:

```sh
git submodule update --init --recursive --depth=1
```

## Building the BoringSSL crypto library for WebAssembly

Generic build for WebAssembly/WASI:

```sh
zig build -Dtarget=wasm32-wasi -Drelease-fast
```

The resulting static library is put into `zig-out/libcrypto.a`.

Build modes:

* `-Drelease-fast`
* `-Drelease-safe`
* `-Drelease-small` (also turns `OPENSSL_SMALL` to disable precomputed tables)
* `-Ddebug` (default, not recommended in production builds)

The resulting library is compatible with the vast majority of WebAssembly runtimes.

Optimizations only compatible with some runtimes can be also enabled:

```sh
zig build -Dtarget=wasm32-wasi -Drelease-fast \
          -Dcpu=generic+simd128+multivalue+bulk_memory
```

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
zig build -Dtarget=native -Drelease-fast
```

Cross-compile to `x86_64-linux`:

```sh
zig build -Dtarget=x86_64-linux -Drelease-small
```

Cross-compile to Apple Silicon:

```sh
zig build -Dtarget=aarch64-macos -Drelease-safe
```