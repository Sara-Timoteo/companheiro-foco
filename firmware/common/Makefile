# Recipes start with ">" instead of a tab (easier to copy and paste).
.RECIPEPREFIX = >
CC      ?= gcc
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Werror -pedantic
LDLIBS  = -lm

all: test lib

lib: libnoise_analyzer.so

libnoise_analyzer.so: noise_analyzer.c noise_analyzer.h
> $(CC) $(CFLAGS) -fPIC -shared -o $@ noise_analyzer.c $(LDLIBS)

test: tests/test_noise_analyzer
> ./tests/test_noise_analyzer

tests/test_noise_analyzer: tests/test_noise_analyzer.c noise_analyzer.c noise_analyzer.h
> $(CC) $(CFLAGS) -D_DEFAULT_SOURCE -o $@ tests/test_noise_analyzer.c noise_analyzer.c $(LDLIBS)

clean:
> rm -f libnoise_analyzer.so tests/test_noise_analyzer

.PHONY: all lib test clean
