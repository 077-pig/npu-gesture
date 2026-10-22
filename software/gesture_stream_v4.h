#ifndef GESTURE_STREAM_V4_H
#define GESTURE_STREAM_V4_H
#include <stdint.h>

/* CRC-32/ISO-HDLC, same final value as Python zlib.crc32. */
static inline uint32_t stream_crc_byte(uint32_t state, uint8_t value)
{
    uint32_t bit;
    state ^= value;
    for (bit = 0u; bit < 8u; ++bit) {
        state = (state >> 1) ^ ((state & 1u) ? 0xEDB88320u : 0u);
    }
    return state;
}

static inline uint32_t stream_crc_u16(uint32_t state, uint16_t value)
{
    state = stream_crc_byte(state, (uint8_t)value);
    return stream_crc_byte(state, (uint8_t)(value >> 8));
}

static inline uint32_t stream_crc_u32(uint32_t state, uint32_t value)
{
    state = stream_crc_u16(state, (uint16_t)value);
    return stream_crc_u16(state, (uint16_t)(value >> 16));
}

/* A return value of -1 denotes a violation of <=1 spike/class/frame. */
#define STREAM_EARLY_MIN_FRAME       8u
#define STREAM_EARLY_REQUIRED_STREAK 3u
#define STREAM_EARLY_REQUIRED_MARGIN 3u

static inline int stream_early_decision(
    const uint16_t counts[11],
    uint32_t processed,
    uint32_t total,
    uint32_t *previous_winner,
    uint32_t *winner_streak,
    uint32_t *winner)
{
    uint32_t index;
    uint32_t best = 0u;
    uint32_t second = 0u;

    if (processed == 0u || processed > total ||
        previous_winner == 0 ||
        winner_streak == 0 ||
        winner == 0) {
        return -1;
    }

    for (index = 0u; index < 11u; ++index) {
        if (counts[index] > processed) {
            return -1;
        }
        if (counts[index] > counts[best]) {
            best = index;
        }
    }

    for (index = 0u; index < 11u; ++index) {
        if (index != best && counts[index] > second) {
            second = counts[index];
        }
    }

    /* A tie does not count as a frame led by one class. */
    if (counts[best] == second) {
        *previous_winner = 0xFFFFFFFFu;
        *winner_streak = 0u;
        *winner = best;
        return 0;
    }

    if (*previous_winner == best) {
        *winner_streak += 1u;
    }
    else {
        *previous_winner = best;
        *winner_streak = 1u;
    }

    *winner = best;

    if (processed < STREAM_EARLY_MIN_FRAME) {
        return 0;
    }

    if (*winner_streak >= STREAM_EARLY_REQUIRED_STREAK &&
        counts[best] - second >= STREAM_EARLY_REQUIRED_MARGIN) {
        return 1;
    }

    return 0;
}
#endif
