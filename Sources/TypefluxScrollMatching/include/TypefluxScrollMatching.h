#ifndef TYPEFLUX_SCROLL_MATCHING_H
#define TYPEFLUX_SCROLL_MATCHING_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    int32_t rowWidth;
    int32_t firstRow;
    int32_t endRow;
    int32_t shiftLimit;
    int32_t minimumRows;
    int32_t closestPercent;
} TypefluxScrollSearch;

// Writes one score per shift from -shiftLimit through shiftLimit, or -1 for insufficient overlap.
// Each byte is one profile bin. The caller supplies matching row widths and valid sampled rows.
void typeflux_scroll_coarse_scores(const uint8_t *current, const uint8_t *reference,
                                  const int32_t *rows, size_t rowCount,
                                  TypefluxScrollSearch search, double *scores);

#endif
