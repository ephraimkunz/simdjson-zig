/*
This file contains a minimal C API, usable by Zig code since it can't bind directly to C++ code. 
It is minimal for performance reasons, and Zig can't inline anything across the FFI boundary.
In the future, an additional C API layer could be added above this to provide nicer access to 
simdjson functionality, similar to what the Zig layer does.
*/

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sj_parser sj_parser;

typedef struct {
    uint64_t *tape_ptr;
    size_t tape_len;
    uint8_t *string_buf_ptr; // We don't store the length, don't need it and it's expensive to calculate.
} sj_tape;

// Create a parser, allocating new memory. Should be freed when done with js_parser_free. This parser internally allocates
// additional memory when sj_parser_parse is called. Should be reused if possible for performance.
sj_parser *sj_parser_new(void);

// Free the memory used to create the parser, and any internal memory it allocated.
void sj_parser_free(sj_parser *p);

// Parse the input string. Should only be called once for a given input string, as it parses all in one go.
int sj_parser_parse(sj_parser *p, const char *buf, size_t len);

// View into sj_parser, so must not outlive that as it references data in the parser. No need to free anything
// when done with this.
// Should only be called after sj_parser_parse is called successfully. Returns null pointers and 0 len if parse was
// unsuccessful.
sj_tape sj_parser_get_tape_view(sj_parser *p);

// Minify the input string. The dest string allocation should be at least as long
// as the input string. dst_len will be set to the actual minified string length.
// Does not validate that input is proper JSON.
int sj_minify(const char *buf, size_t len, char *dst, size_t *dst_len);

// Validate that a string is UTF8.
bool sj_validate_utf8(const char *buf, size_t len);

#ifdef __cplusplus
}
#endif
