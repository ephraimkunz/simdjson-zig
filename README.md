# simdjson-zig
Zig bindings to [simdjson](https://github.com/simdjson/simdjson/tree/master), a SIMD-accelerated JSON parser written in C++.

[View the docs](https://ephraimkunz.github.io/simdjson-zig/#docs.simdjson)


The current version supported is [5.0.4](https://github.com/simdjson/simdjson/releases/tag/v5.0.4).

These bindings support many of the features of simdjson:

| **simdjson feature** | **Supported in simdjson-zig** | **Notes** |
|---|---|---|
| [DOM parsing](https://github.com/simdjson/simdjson/blob/master/doc/dom.md) | ✅ |  |
| [Bigint support](https://github.com/simdjson/simdjson/blob/master/doc/tape.md#big-integers) | ✅ |  |
| [Minify](https://github.com/simdjson/simdjson/blob/master/doc/basics.md#minifying-json-strings-without-parsing) | ✅ |  |
| [UTF8 Validation](https://github.com/simdjson/simdjson/blob/master/doc/basics.md#minifying-json-strings-without-parsing) | ✅ |  |
| [Parse many](https://github.com/simdjson/simdjson/blob/master/doc/parse_many.md) | ✅ | Fast parsing of documents containing many small JSON objects. **TODO**: In progress |
| [OnDemand parsing](https://github.com/simdjson/simdjson/blob/master/doc/basics.md#the-basics-loading-and-parsing-json-documents) | ❌ | Supporting this would be difficult, see [Rust binding documentation](https://github.com/SunDoge/simdjson-rust#why-only-dom-not-ondemand) |
| [Generating JSON output](https://github.com/simdjson/simdjson/blob/master/doc/builder.md) | ❌ | Uses C++ specific features |
| [Compile-time parsing](https://github.com/simdjson/simdjson/blob/master/doc/compile_time.md) | ❌ | Uses C++ specific features |
| Any other feature of simdjson | ❌ | Most of these require C++ specific features that we can't expose cleanly through a binding. |

## Interoperability with Zig JSON APIs
We strive to be a drop-in replacement to the Zig standard library JSON API, allowing you to speed up JSON parsing without having to change much code.
Simply stop importing `std.json` and instead import `simdjson-zig`.

Note that although we support the same error set, and the same success/failure outcome, the specific error can differ on invalid input. This is unavoidable
as we don't have all the same information about the state of the world at the same time as the standard library.

Number will be parsed losslessly but possibly in a slightly different format. This is due to simdjson parsing the number into the tape, but the std library
expecting an unparsed number, resulting in us having to re-serialize a number not knowing the original format.

**TODO** Example.

| **Zig standard library API** | **Identical API in simdjson-zig** | **Notes** |
|---|---|---|
| [parseFromSlice](https://ziglang.org/documentation/master/std/#std.json.static.parseFromSlice) | ✅ | Always behaves as if ParseOptions.allocate == .alloc_always, as it can't return references to the original slice. |
|  |  |  |
|  |  |  |
|  |  |  |
|  | ❌ |  |
|  |  |  |

Additionally, the Zig binding adds new API for functionality simdjson exposes that the standard libraray doesn't:
* `fn minify(str: []const u8, out_buf: []u8) err.Error!usize` to minifiy JSON strings without parsing.
* `pub fn validate_utf8(str: []const u8) bool` to validate that a sequence of bytes are UTF-8 encoded.


## Tips for speed
**TODO**
* Reuse the parser by using APIs which take a token source, rather than those that take just a string to parse from?
* Memory upper limits or fixed capacity for long-runnign services. 
* See [simdjson docs](https://github.com/simdjson/simdjson/blob/master/doc/performance.md) for more ideas.

## How it works
simdjson parses a JSON document in two stages: stage1 scans the input with SIMD to find structural characters, stage2 builds a [flat tape](https://github.com/simdjson/simdjson/blob/master/doc/tape.md) — an array of 64-bit words encoding every value with its type tag and payload, plus a side string buffer holding all (already-unescaped) string bytes.

This package exposes that tape through a C wrapper around the original simdjson C++ code, then implements higher-level functionality to walk it and expose it through APIs 
very similar to the JSON APIs in the standard library. This allows us to reuse parsing code in the std library and maintain familiar APIs, but all on top of a simd-accelerated tape backend.


**TODO**: benchmark vs yyjson / std.json, expand API:
* Load many?, parse many
* Finish implementing drop-in std.json support. test with jsonparse
* Prettify? write out in general?
* Update simdjson readme with a reference.
* Reviews from Ziggit.
* Test if it's really drop in by adding example programs.
* Fuzzing and testing, especially with max nesting level and allocations enabled.
* Benchmarks sections showing speed vs c++ impl direct and std.json 
* A tape to std.json.Value converter, and a comptime struct decoder that reads i64/u64/f64 straight from the tape?
* Validate JSON?
* Finish readme
* Test for common mistakes, like reusing the token multiple times, or accessing memory from the scanner from the previous run after the scanner has been used, threading
* Provide a nice commandline json parser in the main executable.
