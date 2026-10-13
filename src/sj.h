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
    uint8_t *string_buf_ptr;
    size_t string_buf_len;
} sj_tape;

// Parsing
sj_parser *sj_parser_new(void);
void sj_parser_free(sj_parser *p);
int sj_parser_parse(sj_parser *p, const char *buf, size_t len);
sj_tape sj_parser_get_tape_view(sj_parser *p);
void sj_tape_free(sj_tape *t);

// Other utility functions
int sj_minify(const char *buf, size_t len, char *dst, size_t *dst_len);
bool sj_validate_utf8(const char *buf, size_t len);

#ifdef __cplusplus
}
#endif
