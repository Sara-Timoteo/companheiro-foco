#include "../noise_analyzer.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (cond) { printf("PASS  %s\n", msg); } \
    else { printf("FAIL  %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/* feed one reading per second, return the first event seen (or NA_NONE) */
static na_event_t feed(noise_analyzer_t *a, int32_t level, int seconds, uint32_t *t, int *at)
{
    na_event_t first = NA_NONE;
    for (int i = 0; i < seconds; i++) {
        *t += 1000;
        na_event_t e = na_update(a, level, *t);
        if (e != NA_NONE && first == NA_NONE) {
            first = e;
            if (at) *at = i + 1;
        }
    }
    return first;
}

int main(void)
{
    noise_analyzer_t a;
    uint32_t t = 0;
    int at = 0;

    na_init(&a, 6500, 8000);
    feed(&a, 4200, 20, &t, NULL);
    CHECK(feed(&a, 8000, 1, &t, NULL) == NA_NONE && !na_is_loud(&a),
          "a single 80 dB bang does not trigger a cue");
    feed(&a, 4200, 10, &t, NULL);

    na_event_t e = feed(&a, 7200, 30, &t, &at);
    CHECK(e == NA_NOISE_HIGH, "sustained 72 dB triggers noise_high");
    CHECK(at >= 9 && at <= 14, "noise_high only after the 8 s sustain time");

    CHECK(feed(&a, 6350, 20, &t, NULL) == NA_NONE && na_is_loud(&a),
          "hysteresis: hovering just under the limit stays loud");

    CHECK(feed(&a, 4200, 20, &t, NULL) == NA_NOISE_OK && !na_is_loud(&a),
          "back to calm triggers noise_ok");

    na_set_limits(&a, 8000, 8000);
    CHECK(feed(&a, 7200, 30, &t, NULL) == NA_NONE,
          "a higher limit set by the person is respected");

    /* millisecond counter wrap-around (every ~49 days on 32-bit) */
    noise_analyzer_t w;
    uint32_t tw = 0xFFFFFFFFu - 3000u;
    na_init(&w, 6500, 8000);
    feed(&w, 4200, 5, &tw, NULL);
    CHECK(feed(&w, 7500, 30, &tw, NULL) == NA_NOISE_HIGH, "works across a 32-bit ms wrap");

    /* RMS to dBFS: full-scale sine is -3.01 dBFS, silence is the floor */
    int16_t buf[480];
    for (int i = 0; i < 480; i++) {
        buf[i] = (int16_t)lround(32767.0 * sin(2.0 * M_PI * i / 48.0));
    }
    int32_t db = na_rms_dbfs_cdb(buf, 480);
    CHECK(db >= -305 && db <= -297, "full-scale sine measures -3.01 dBFS");
    for (int i = 0; i < 480; i++) buf[i] = (int16_t)(buf[i] / 10);
    db = na_rms_dbfs_cdb(buf, 480);
    CHECK(db >= -2305 && db <= -2297, "sine at 1/10 measures -23 dBFS");
    for (int i = 0; i < 480; i++) buf[i] = 0;
    CHECK(na_rms_dbfs_cdb(buf, 480) == -9600, "silence returns the -96 dBFS floor");

    printf("%d failed\n", failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
