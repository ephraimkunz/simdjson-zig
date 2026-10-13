#include "sj.h"

// Set to 0 once we've fully tested everything.
#define SIMDJSON_DEVELOPMENT_CHECKS 1
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
    int error = p->parser.parse(buf, len).error();
    return error;
}

sj_tape sj_parser_get_tape_view(sj_parser *p) {
    sj_tape tape = {};
    tape.string_buf_len = 0;
    tape.string_buf_ptr = NULL;
    tape.tape_len = 0;
    tape.tape_ptr = NULL;

    const uint64_t JSON_VALUE_MASK = 0x00FFFFFFFFFFFFFF;

    auto &doc = p->parser.doc;

    if (!doc.tape || !doc.string_buf) {
        return tape;
    }

    size_t tape_len = doc.tape[0] & JSON_VALUE_MASK;
    if (tape_len == 0) {
        return tape;
    }

    tape.tape_ptr = doc.tape.get();
    tape.tape_len = tape_len;

    // Only expose initialized string bytes, never unused allocation capacity.
    // Numeric payload words are arbitrary bits and must not be read as tags.
    size_t string_buf_len = 0;
    for (size_t i = 1; i < tape_len; ++i) {
        const auto tag = static_cast<uint8_t>(doc.tape[i] >> 56);
        if (tag == '"') {
            const size_t offset = static_cast<size_t>(doc.tape[i] & JSON_VALUE_MASK);
            uint32_t length;
            std::memcpy(&length, doc.string_buf.get() + offset, sizeof(length));
            string_buf_len = std::max(string_buf_len, offset + sizeof(length) + length + 1);
        } else if (tag == 'l' || tag == 'u' || tag == 'd') {
            ++i;
        }
    }

    tape.string_buf_ptr = doc.string_buf.get();
    tape.string_buf_len = string_buf_len;

    return tape;
}

void sj_tape_free(sj_tape *t) {
    delete t;
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
