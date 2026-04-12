// =============================================================================
// File        : crc32.h
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : CRC-32 software implementation — interface.
//               Supports CRC-32/IEEE 802.3 and CRC-32C (Castagnoli),
//               matching the two algorithms selectable in the IP via CRC_CTRL.
// =============================================================================

#ifndef CRC32_H
#define CRC32_H

#include <stddef.h>
#include <stdint.h>

// Matches CRC_CTRL.ALG_SEL register encoding (0 = IEEE, 1 = Castagnoli).
typedef enum {
    CRC32_IEEE8023   = 0,   // Polynomial 0x04C11DB7 (reflected: 0xEDB88320)
    CRC32_CASTAGNOLI = 1    // Polynomial 0x1EDC6F41 (reflected: 0x82F63B78)
} crc32_alg_t;

// Compute CRC-32 over data[0..len-1].
// Parameters match the algorithm used by the IP hardware:
//   - Initial value  : 0xFFFFFFFF
//   - Input/output   : reflected (bit-reversed)
//   - Final XOR      : 0xFFFFFFFF
uint32_t crc32_compute(crc32_alg_t alg, const uint8_t *data, size_t len);

#endif // CRC32_H
