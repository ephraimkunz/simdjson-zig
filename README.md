# simdjson-zig
Zig bindings to [simdjson](https://github.com/simdjson/simdjson/tree/master), a SIMD-accelerated JSON parser written in C++.

[View the docs](https://ephraimkunz.github.io/simdjson-zig/#docs.simdjson)


The current version supported is [5.1.1](https://github.com/simdjson/simdjson/releases/tag/v5.1.1).

These bindings support many of the features of simdjson:

| **simdjson feature** | **Supported in simdjson-zig** | **Notes** |
|---|---|---|
| [DOM parsing](https://github.com/simdjson/simdjson/blob/master/doc/dom.md) | ✅ |  |
| [Bigint support](https://github.com/simdjson/simdjson/blob/master/doc/tape.md#big-integers) | ✅ |  |
| [Minify](https://github.com/simdjson/simdjson/blob/master/doc/basics.md#minifying-json-strings-without-parsing) | ✅ |  |
| [UTF8 Validation](https://github.com/simdjson/simdjson/blob/master/doc/basics.md#utf-8-validation-alone) | ✅ |  |
| Optional [zero copy parsing](https://github.com/simdjson/simdjson/blob/master/doc/dom.md#parsing-without-padding) |  ✅ | Sometimes zero copy is faster, sometimes it is slower, depends on the size of the input |
| [OnDemand parsing](https://github.com/simdjson/simdjson/blob/master/doc/basics.md#the-basics-loading-and-parsing-json-documents) | ❌ | Supporting this would be difficult, see [Rust binding documentation](https://github.com/SunDoge/simdjson-rust#why-only-dom-not-ondemand) |
| [Generating JSON output](https://github.com/simdjson/simdjson/blob/master/doc/builder.md) | ❌ | Uses C++ specific features |
| [Compile-time parsing](https://github.com/simdjson/simdjson/blob/master/doc/compile_time.md) | ❌ | Uses C++ specific features |
| Any other feature of simdjson | ❌ | Most of these require C++ specific features that we can't expose cleanly through a binding. |

## Interoperability with Zig JSON APIs
We strive to be a drop-in replacement to the Zig standard library JSON API, allowing you to speed up JSON parsing without having to change much code.
Simply stop importing `std.json` and instead import `simdjson`.

The supported parsing functions use the same error sets as `std.json`, but the specific error returned for invalid input can differ
because the parsers detect errors at different stages.

Numeric behavior follows simdjson's tape representation. Decimal and exponent forms are converted to `f64` before conversion to the
requested Zig type. This can reduce precision or affect integer conversion, including when `parse_numbers = false`. Numbers outside
the finite `f64` range may be rejected. Large integer literals without a decimal point or exponent are preserved as text through
bigint support. Original numeric spelling and negative zero are not always preserved.

**TODO** Example.

| **Zig standard library API** | **Identical API in simdjson-zig** | **Notes** |
|---|---|---|
| [parseFromSlice](https://ziglang.org/documentation/master/std/#std.json.static.parseFromSlice) | ✅ | Always behaves as if ParseOptions.allocate == .alloc_always, as it can't return references to the original slice. |
|  |  |  |
|  |  |  |
|  |  |  |
|  | ❌ |  |
|  |  |  |

Additionally, the Zig binding adds new API for functionality simdjson exposes that the standard library doesn't:
* `fn minify(str: []const u8, out_buf: []u8) MinifyError![]u8` to minify JSON strings without parsing.
* `pub fn validateUTF8(str: []const u8) bool` to validate that a sequence of bytes are UTF-8 encoded.
* `pub fn validate(allocator: Allocator, s: []const u8) std.mem.Allocator.Error!bool` to scan the input and check for malformed JSON.


## Tips for speed
**TODO**
* Reuse the parser by using APIs which take a token source, rather than those that take just a string to parse from?
* Memory upper limits or fixed capacity for long-runnign services. 
* See [simdjson docs](https://github.com/simdjson/simdjson/blob/master/doc/performance.md) for more ideas.

## How it works
simdjson parses a JSON document in two stages: stage1 scans the input with SIMD to find structural characters, stage2 builds a [flat tape](https://github.com/simdjson/simdjson/blob/master/doc/tape.md) — an array of 64-bit words encoding every value with its type tag and payload, plus a side string buffer holding all (already-unescaped) string bytes.

This package exposes that tape through a C wrapper around the original simdjson C++ code, then implements higher-level functionality to walk it and expose it through APIs 
very similar to the JSON APIs in the standard library. This allows us to reuse parsing code in the std library and maintain familiar APIs, but all on top of a simd-accelerated tape backend.


**TODO**: 
* benchmark vs yyjson / std.json
* Benchmark large, small, mmap, zero copy, Reusing / perf of tapeparser?
* Benchmarks sections showing speed vs c++ impl direct and std.json 

* Update simdjson readme with a reference.
* Finish readme
    * Doc memory usage:  Note that this simdjson functions uses more memory as it parses the entire JSON file in memory up front, instead of walking it on demand.
* Reviews from Ziggit.
* Find way to warn on not freeing tapeparser / tapetokensource, or provide way to run with `leaks`.
* Mark zero-copy as experimental in doc + readme

* Update lifetime docs:  “Lifetimes” section on the package, and a short example in the README.

Lifetime is tied to the parser instance if alloc_if_needed, not the input, in zero copy and non-zero copy. If alloc_always is passed, lifetime is tied to the arena returned by std.json.Parsed. 

This differs from std.json's lifetime, which is tied to the input if alloc_if_needed.
parseFromSlice internally uses a parser instance that is allocated and deallocated, so it forces alloc_always. You can get around this by using parseFromTokenSource with your own parser + alloc_if_needed.

/// If true (default), parse in place without making simdjson's padded copy.
/// Faster and uses less memory on large inputs; no measurable difference on tiny ones.

zig
/// Lifetimes
///
/// - Parsing is lazy: init() only stores the slice, and the document is parsed on the
///   first token or peek. The input must not be freed or modified between init() and
///   the end of parsing, not just during init().
/// - Tokens never point into your input. Strings from next() (and from nextAlloc* with
///   .alloc_if_needed) point into the parser's buffer, valid until that parser parses
///   another document or is freed. Numbers are formatted into a scratch buffer and are
///   valid only until the next call.
/// - Values produced by std.json with .alloc_always own their memory and outlive the parser.
