#include "pressure_sim.h"

#include <math.h>
#include <stdlib.h>

#include "tire_pressure.h"

/*
 * DUMMY pressure source.
 * Simulates a tire: after the app sets a target, the measured value walks
 * towards it gradually (a compressor takes time), then jitters slightly
 * around it like a real sensor would. Swap this file for a real sensor
 * driver later; the interface stays identical.
 */

static float s_current; /* measured bar */
static float s_target;  /* requested bar */

/* tiny PRNG so jitter is not always the same pattern */
static uint32_t s_rand_state = 0xC0FFEE42u;
static uint32_t next_rand(void)
{
    s_rand_state ^= s_rand_state << 13;
    s_rand_state ^= s_rand_state >> 17;
    s_rand_state ^= s_rand_state << 5;
    return s_rand_state;
}

static float clamp_bar(float v)
{
    if (v < PRESSURE_MIN) return PRESSURE_MIN;
    if (v > PRESSURE_MAX) return PRESSURE_MAX;
    return v;
}

void pressure_sim_init(void)
{
    s_current = 2.30f + (next_rand() % 21) / 100.0f; /* 2.30 - 2.50 */
    s_target  = s_current;
}

float pressure_sim_get(void)
{
    return s_current;
}

float pressure_sim_target(void)
{
    return s_target;
}

void pressure_sim_set_target(float bar)
{
    s_target = clamp_bar(bar);
}

/* Called from the BLE task every tick (see main.c). */
void pressure_sim_tick(void)
{
    const float step = 0.04f; /* bar per tick, ~compressor speed */

    if (fabsf(s_current - s_target) > 0.01f) {
        /* still filling / venting towards the target */
        if (s_current < s_target) s_current += step;
        else                      s_current -= step;
    } else {
        /* at target: realistic sensor noise +-0.01 bar */
        s_current += ((int32_t)(next_rand() % 3) - 1) * 0.01f;
    }
    s_current = clamp_bar(s_current);
}
