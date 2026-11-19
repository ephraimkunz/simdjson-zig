// Simple yyjson CLI: reads JSON from stdin until EOF.
//
// Build:
//   cc -O3 -o yyjson_cli yyjson_cli.c yyjson.c
//
// Usage:
//   yyjson_cli validate < file.json   (prints true/false, exit 0/1)
//   yyjson_cli minify   < file.json   (prints minified JSON)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "yyjson.h"

#define MAX_INPUT_SIZE 2000000000ULL

static void usage(const char *exe) {
    fprintf(stderr,
            "Usage: %s <subcommand>\n\n"
            "Subcommands:\n"
            "  validate: return 0 if valid JSON, otherwise 1. Outputs true or false on stdout.\n"
            "  minify: return 0 on success, otherwise non 0. Outputs minified JSON on stdout.\n\n"
            "All subcommands take input from stdin (reading until EOF), and write output and errors\n"
            "to stdout and stderr, respectively. Redirect from these as needed.\n",
            exe);
}

// Reads all of stdin into a malloc'd buffer (NUL-padded). Returns NULL on error.
static char *read_stdin(size_t *out_len) {
    size_t cap = 1 << 20;
    size_t len = 0;
    char *buf = malloc(cap + YYJSON_PADDING_SIZE);
    if (!buf) return NULL;

    for (;;) {
        if (len == cap) {
            if (cap >= MAX_INPUT_SIZE) {
                // Buffer is at the limit; make sure there's truly nothing left.
                int c = fgetc(stdin);
                if (c == EOF) break;
                fprintf(stderr, "error: input too long\n");
                free(buf);
                return NULL;
            }
            cap *= 2;
            if (cap > MAX_INPUT_SIZE) cap = MAX_INPUT_SIZE;
            char *nbuf = realloc(buf, cap + YYJSON_PADDING_SIZE);
            if (!nbuf) {
                free(buf);
                return NULL;
            }
            buf = nbuf;
        }
        size_t n = fread(buf + len, 1, cap - len, stdin);
        len += n;
        if (n == 0) {
            if (ferror(stdin)) {
                fprintf(stderr, "error: read failed\n");
                free(buf);
                return NULL;
            }
            break; // EOF
        }
    }

    memset(buf + len, 0, YYJSON_PADDING_SIZE);
    *out_len = len;
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        usage(argc >= 1 ? argv[0] : "yyjson_cli");
        return 1;
    }

    enum { CMD_VALIDATE, CMD_MINIFY } cmd;
    if (strcmp(argv[1], "validate") == 0) {
        cmd = CMD_VALIDATE;
    } else if (strcmp(argv[1], "minify") == 0) {
        cmd = CMD_MINIFY;
    } else {
        fprintf(stderr,
                "\"%s\" is not a valid subcommand.\n\nOptions are:\n  validate\n  minify\n",
                argv[1]);
        return 1;
    }

    size_t len = 0;
    char *input = read_stdin(&len);
    if (!input) return 1;

    int rc = 0;

    if (cmd == CMD_VALIDATE) {
        yyjson_doc *doc = yyjson_read(input, len, 0);
        if (doc) {
            fputs("true\n", stdout);
            yyjson_doc_free(doc);
        } else {
            fputs("false\n", stdout);
            rc = 1;
        }
    } else {
        // NUMBER_AS_RAW keeps numbers byte-for-byte (like a minifier), instead of
        // re-formatting them (e.g. 1e5 -> 100000.0).
        yyjson_read_err err;
        yyjson_doc *doc = yyjson_read_opts(input, len, YYJSON_READ_NUMBER_AS_RAW, NULL, &err);
        if (!doc) {
            fprintf(stderr, "error: %s at byte %zu\n", err.msg, err.pos);
            rc = 1;
        } else {
            size_t out_len = 0;
            yyjson_write_err werr;
            char *out = yyjson_write_opts(doc, YYJSON_WRITE_NOFLAG, NULL, &out_len, &werr);
            if (!out) {
                fprintf(stderr, "error: write failed: %s\n", werr.msg);
                rc = 1;
            } else {
                fwrite(out, 1, out_len, stdout);
                fputc('\n', stdout);
                free(out);
            }
            yyjson_doc_free(doc);
        }
    }

    free(input);
    return rc;
}
