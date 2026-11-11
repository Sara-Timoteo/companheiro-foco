/*
 * Noise analyzer for the Focus Companion sensor node.
 *
 * Same logic as the Python simulator: smooth the level, and report noise only
 * when it stays above the person's limit for a while (a single bang never
 * triggers a cue). Fixed point (centi-dB), no heap, constant time per sample,
 * so it runs unchanged on a microcontroller (ESP32 / FreeRTOS) or on Linux.
 */
#ifndef NOISE_ANALYZER_H
#define NOISE_ANALYZER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NA_HYSTERESIS_CDB 300   /* 3 dB below the limit before "calm again" */

typedef enum { NA_NONE = 0, NA_NOISE_HIGH = 1, NA_NOISE_OK = 2 } na_event_t;

typedef struct {
    int32_t  threshold_cdb;   /* limit set by the person, in centi-dB */
    uint32_t sustain_ms;      /* how long the level must stay above the limit */
    int32_t  avg_cdb;         /* smoothed level */
    uint32_t above_since_ms;
    uint8_t  has_avg;
    uint8_t  above;
    uint8_t  loud;
} noise_analyzer_t;

void       na_init(noise_analyzer_t *a, int32_t threshold_cdb, uint32_t sustain_ms);
void       na_set_limits(noise_analyzer_t *a, int32_t threshold_cdb, uint32_t sustain_ms);
na_event_t na_update(noise_analyzer_t *a, int32_t level_cdb, uint32_t now_ms);
int32_t    na_avg_cdb(const noise_analyzer_t *a);
int        na_is_loud(const noise_analyzer_t *a);

/* RMS of 16-bit PCM samples in centi-dBFS (0 = full scale, -9600 = silence).
 * A real device adds its own calibration offset to get dB SPL. */
int32_t    na_rms_dbfs_cdb(const int16_t *samples, size_t count);

#ifdef __cplusplus
}
#endif

#endif /* NOISE_ANALYZER_H */
