#include "sj.h"

#define SIMDJSON_DEVELOPMENT_CHECKS 0
#define NDEBUG
#define SIMDJSON_EXCEPTIONS 0
#define SIMDJSON_DISABLE_DEPRECATED_API 1
#include "../vendor/simdjson.h"

struct sj_parser {
    simdjson::dom::parser parser;
};

sj_parser *sj_parser_new(void) {
    return new sj_parser;
}

void sj_parser_free(sj_parser *p) {
    delete p;
}

int sj_parser_parse(sj_parser *p, const char *buf, size_t len) {
    int error = p->parser.parse(buf, len, true).error();
    return error;
}

sj_tape sj_parser_get_tape_view(sj_parser *p) {
    sj_tape tape = {};
    tape.string_buf_ptr = NULL;
    tape.tape_len = 0;
    tape.tape_ptr = NULL;

    auto &doc = p->parser.doc;

    if (!doc.tape || !doc.string_buf) {
        return tape;
    }

    size_t tape_len = doc.tape[0] & 0x00FFFFFFFFFFFFFF;
    if (tape_len == 0) {
        return tape;
    }

    tape.tape_ptr = doc.tape.get();
    tape.tape_len = tape_len;
    tape.string_buf_ptr = doc.string_buf.get();

    return tape;
}

int sj_minify(const char *buf, size_t len, char *dst, size_t *dst_len) {
    size_t minify_out_len = 0;
    int result = simdjson::minify(buf, len, dst, minify_out_len);
    *dst_len = minify_out_len;
    return result;
}

bool sj_validate_utf8(const char *buf, size_t len) {
    return simdjson::validate_utf8(buf, len);
}
