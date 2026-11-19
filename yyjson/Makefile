CC      ?= cc
CFLAGS  ?= -O3 -DNDEBUG -march=native -std=c11 -Wall -Wextra

cli: cli.c yyjson.c yyjson.h
	$(CC) $(CFLAGS) -o $@ cli.c yyjson.c

clean:
	rm -f yyjson_cli

.PHONY: clean
