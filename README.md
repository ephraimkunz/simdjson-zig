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
| [UTF8 Validation](https://github.com/simdjson/simdjson/blob/master/doc/basics.md#utf-8-validation-alone) | ✅ |  |
| [Parse many](https://github.com/simdjson/simdjson/blob/master/doc/parse_many.md) | ✅ | Fast parsing of documents containing many small JSON objects. **TODO**: In progress |
| Optional [zero copy parsing](https://github.com/simdjson/simdjson/blob/master/doc/dom.md#parsing-without-padding) |  ✅ | Sometimes zero copy is faster, sometimes it is slower, depends on the size of the input |
| [OnDemand parsing](https://github.com/simdjson/simdjson/blob/master/doc/basics.md#the-basics-loading-and-parsing-json-documents) | ❌ | Supporting this would be difficult, see [Rust binding documentation](https://github.com/SunDoge/simdjson-rust#why-only-dom-not-ondemand) |
| [Generating JSON output](https://github.com/simdjson/simdjson/blob/master/doc/builder.md) | ❌ | Uses C++ specific features |
| [Compile-time parsing](https://github.com/simdjson/simdjson/blob/master/doc/compile_time.md) | ❌ | Uses C++ specific features |
| Any other feature of simdjson | ❌ | Most of these require C++ specific features that we can't expose cleanly through a binding. |

## Interoperability with Zig JSON APIs
We strive to be a drop-in replacement to the Zig standard library JSON API, allowing you to speed up JSON parsing without having to change much code.
Simply stop importing `std.json` and instead import `simdjson`.

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
* `fn minify(str: []const u8, out_buf: []u8) err.Error![]u8` to minifiy JSON strings without parsing.
* `pub fn validateUTF8(str: []const u8) bool` to validate that a sequence of bytes are UTF-8 encoded.
* `pub fn validate(s: []const u8) std.mem.Allocator.Error!bool` to scan the input and check for malformed JSON.


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
* Update simdjson readme with a reference.
* Reviews from Ziggit.
* Test if it's really drop in by adding example programs.
* Benchmarks sections showing speed vs c++ impl direct and std.json 
* Finish readme
* Test for common mistakes, like reusing the token multiple times, or accessing memory from the scanner from the previous run after the scanner has been used, threading, zero copy ownership, add aliasing guard?
* Benchmark large, small, mmap, zero copy.

I’d put it in three places: the zero_copy option, a “Lifetimes” section on TapeTokenSource, and a short example in the README. The key facts to state are who must keep what alive, and until when.

On the option:

zig
/// If true (default), parse in place without making simdjson's padded copy.
/// Faster and uses less memory on large inputs; no measurable difference on tiny ones.
///
/// Requirement: the input slice passed to TapeTokenSource must stay alive and
/// unmodified from init() until you are finished with the token source. See the
/// "Lifetimes" notes on TapeTokenSource.
///
/// Set to false if you can't guarantee that (e.g. the buffer is reused for the next
/// read, or another thread may free it). The input can then be discarded as soon as
/// parsing returns, at the cost of a temporary padded copy.
zero_copy: bool = true,

On TapeTokenSource:

zig
/// Lifetimes
///
/// - Parsing is lazy: init() only stores the slice, and the document is parsed on the
///   first token or peek. The input must not be freed or modified between init() and
///   the end of parsing, not just during init().
/// - With zero_copy, keep the input alive until you are done with the token source.
///   This is simdjson's own rule for parse_unpadded.
/// - The input is only read, never written, and parsing never reads past its end.
///   A bad lifetime is a use-after-free, not an out-of-bounds read.
/// - Tokens never point into your input. Strings from next() (and from nextAlloc* with
///   .alloc_if_needed) point into the parser's buffer, valid until that parser parses
///   another document or is freed. Numbers are formatted into a scratch buffer and are
///   valid only until the next call.
/// - Values produced by std.json with .alloc_always own their memory and outlive both
///   the input and the parser.
/// - If the input comes from mmap, truncating the file during parsing can raise SIGBUS.

In the README, with one example of each:

zig
// OK: input outlives the parse; the result owns its memory.
const bytes = try std.fs.cwd().readFileAlloc(alloc, "data.json", max);
defer alloc.free(bytes);
var src = TapeTokenSource.init(bytes);
defer src.deinit();
const parsed = try std.json.parseFromTokenSource(T, alloc, &src, .{});
defer parsed.deinit(); // safe to use even after `bytes` is freed

// Bug with zero_copy: buffer reused before the token source is finished.
var src = TapeTokenSource.init(read_buf[0..n]);
@memcpy(read_buf[0..m], next_chunk); // overwrites input before first token is read
_ = try src.next();                  // parses garbage

I haven’t checked the claim that tokens never point into the input against the shim, only against the Zig code and simdjson’s DOM, which unescapes strings into its own buffer. Keep the “must stay alive until done” wording regardless, since it’s simdjson’s documented rule and costs users nothing. A test that frees or overwrites the input right after parseFromTokenSource returns would confirm the result really owns its data.  
