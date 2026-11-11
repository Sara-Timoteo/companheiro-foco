#include "noise_analyzer.h"

#include <math.h>

void na_init(noise_analyzer_t *a, int32_t threshold_cdb, uint32_t sustain_ms)
{
    a->avg_cdb = 0;
    a->above_since_ms = 0;
    a->has_avg = 0;
    a->above = 0;
    a->loud = 0;
    na_set_limits(a, threshold_cdb, sustain_ms);
}

void na_set_limits(noise_analyzer_t *a, int32_t threshold_cdb, uint32_t sustain_ms)
{
    a->threshold_cdb = threshold_cdb;
    a->sustain_ms = sustain_ms;
}

na_event_t na_update(noise_analyzer_t *a, int32_t level_cdb, uint32_t now_ms)
{
    /* exponential moving average, alpha = 0.3, rounded */
    if (!a->has_avg) {
        a->avg_cdb = level_cdb;
        a->has_avg = 1;
    } else {
        int32_t sum = 3 * level_cdb + 7 * a->avg_cdb;
        a->avg_cdb = (sum >= 0 ? sum + 5 : sum - 5) / 10;
    }

    if (a->avg_cdb >= a->threshold_cdb) {
        if (!a->above) {
            a->above = 1;
            a->above_since_ms = now_ms;
        }
        /* unsigned subtraction keeps working when the ms counter wraps */
        if (!a->loud && (uint32_t)(now_ms - a->above_since_ms) >= a->sustain_ms) {
            a->loud = 1;
            return NA_NOISE_HIGH;
        }
    } else {
        a->above = 0;
        if (a->loud && a->avg_cdb < a->threshold_cdb - NA_HYSTERESIS_CDB) {
            a->loud = 0;
            return NA_NOISE_OK;
        }
    }
    return NA_NONE;
}

int32_t na_avg_cdb(const noise_analyzer_t *a) { return a->avg_cdb; }

int na_is_loud(const noise_analyzer_t *a) { return a->loud; }

int32_t na_rms_dbfs_cdb(const int16_t *samples, size_t count)
{
    uint64_t sum_sq = 0;
    for (size_t i = 0; i < count; i++) {
        int32_t s = samples[i];
        sum_sq += (uint64_t)(s * s);
    }
    if (count == 0 || sum_sq == 0) {
        return -9600;
    }
    double rms = sqrt((double)sum_sq / (double)count) / 32768.0;
    double db = 20.0 * log10(rms);
    if (db < -96.0) {
        db = -96.0;
    }
    return (int32_t)lround(db * 100.0);
}
