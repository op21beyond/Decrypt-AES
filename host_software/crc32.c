// =============================================================================
// File        : crc32.c
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : CRC-32 software implementation.
//               Table-based (256-entry, single-step per byte) using the
//               reflected-polynomial form, matching the hardware engine.
// =============================================================================

#include "crc32.h"

// Reflected polynomial constants:
//   IEEE 802.3 : bit-reversal of 0x04C11DB7
//   Castagnoli : bit-reversal of 0x1EDC6F41
#define POLY_IEEE8023   0xEDB88320u
#define POLY_CASTAGNOLI 0x82F63B78u

// Build a 256-entry lookup table for the given reflected polynomial.
static void build_table(uint32_t tbl[256], uint32_t poly)
{
    for (uint32_t i = 0; i < 256u; i++) {
        uint32_t crc = i;
        for (int k = 0; k < 8; k++)
            crc = (crc >> 1) ^ ((crc & 1u) ? poly : 0u);
        tbl[i] = crc;
    }
}

uint32_t crc32_compute(crc32_alg_t alg, const uint8_t *data, size_t len)
{
    uint32_t tbl[256];
    build_table(tbl, (alg == CRC32_IEEE8023) ? POLY_IEEE8023 : POLY_CASTAGNOLI);

    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++)
        crc = (crc >> 8) ^ tbl[(crc ^ data[i]) & 0xFFu];

    return crc ^ 0xFFFFFFFFu;
}
