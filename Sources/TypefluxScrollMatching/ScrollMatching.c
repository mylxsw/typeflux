#include "TypefluxScrollMatching.h"
#include <stdlib.h>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

static unsigned profile_distance(const uint8_t *left, const uint8_t *right, int32_t width) {
#if defined(__ARM_NEON)
    if (width == 32) {
        uint8x16_t first = vabdq_u8(vld1q_u8(left), vld1q_u8(right));
        uint8x16_t second = vabdq_u8(vld1q_u8(left + 16), vld1q_u8(right + 16));
        return (vaddlvq_u8(first) + vaddlvq_u8(second)) / 32;
    }
#endif
    unsigned distance = 0;
    for (int32_t bin = 0; bin < width; ++bin) {
        distance += (unsigned)abs((int)left[bin] - (int)right[bin]);
    }
    return distance / (unsigned)width;
}

void typeflux_scroll_coarse_scores(const uint8_t *current, const uint8_t *reference,
                                  const int32_t *rows, size_t rowCount,
                                  TypefluxScrollSearch search, double *scores) {
    for (int32_t shift = -search.shiftLimit; shift <= search.shiftLimit; ++shift) {
        // A histogram gives the same trimmed average as sorting the byte distances.
        unsigned counts[256] = {0};
        unsigned matched = 0;
        for (size_t index = 0; index < rowCount; ++index) {
            int32_t row = rows[index];
            int32_t otherRow = row + shift;
            if (otherRow >= search.firstRow && otherRow < search.endRow) {
                unsigned distance = profile_distance(current + row * search.rowWidth,
                    reference + otherRow * search.rowWidth, search.rowWidth);
                ++counts[distance];
                ++matched;
            }
        }
        size_t output = (size_t)(shift + search.shiftLimit);
        if (matched < (unsigned)search.minimumRows) {
            scores[output] = -1;
            continue;
        }
        unsigned kept = matched * (unsigned)search.closestPercent / 100;
        if (kept == 0) {
            kept = 1;
        }
        unsigned remaining = kept;
        unsigned sum = 0;
        for (unsigned distance = 0; remaining > 0; ++distance) {
            unsigned count = counts[distance] < remaining ? counts[distance] : remaining;
            sum += count * distance;
            remaining -= count;
        }
        scores[output] = (double)sum / kept;
    }
}
