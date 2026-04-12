// =============================================================================
// File        : tc_params.h
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : 10 parameterised test-case definitions covering a wide range
//               of ciphertext sizes (16 B – 1 MiB) and padding lengths.
//
//               Used by:
//                 host_software/sw_test.c
//                 design/tb/gen_mem.c   (via -I../../host_software)
//
//               Plaintext pattern:  pt[i] = (uint8_t)(i & 0xFF)
//               Key / Nonce / CTR : TV_KEY / TV_NONCE / TV_INIT_CTR
//               (NIST SP 800-38A F.5.1 — same as existing test vectors)
//
// Case overview:
//   TC0   16 B       0 B pad   IEEE-802.3    1 AES block, minimum size
//   TC1   48 B       0 B pad   Castagnoli    3 blocks, no padding
//   TC2   64 B       0 B pad   IEEE-802.3    4 blocks, no padding
//   TC3   96 B      32 B pad   Castagnoli    6 blocks + 2-block pad
//   TC4  192 B      64 B pad   IEEE-802.3   12 blocks + 4-block pad
//   TC5  512 B       0 B pad   Castagnoli   32 blocks, no padding
//   TC6 1024 B     128 B pad   IEEE-802.3   64 blocks + 8-block pad
//   TC7 4096 B       0 B pad   Castagnoli  256 blocks, 4 KiB
//   TC8 65536 B    256 B pad   IEEE-802.3  4096 blocks + 16-block pad, 64 KiB
//   TC9 1048576 B    0 B pad   Castagnoli 65536 blocks, 1 MiB
// =============================================================================

#ifndef TC_PARAMS_H
#define TC_PARAMS_H

#include <stdint.h>
#include <string.h>
#include "crc32.h"

// ---------------------------------------------------------------------------
// Test-case descriptor
// ---------------------------------------------------------------------------
typedef struct {
    const char  *name;
    uint32_t     data_bytes;    // ciphertext / plaintext length (AES-block multiple)
    uint32_t     pad_bytes;     // padding bytes between ciphertext and CRC in inbuf
    crc32_alg_t  crc_alg;
} tc_param_t;

#define TC_COUNT  10u

static const tc_param_t TC_PARAMS[TC_COUNT] = {
    /* 0 */ { "TC0_16B",          16,       0, CRC32_IEEE8023   },
    /* 1 */ { "TC1_48B",          48,       0, CRC32_CASTAGNOLI },
    /* 2 */ { "TC2_64B",          64,       0, CRC32_IEEE8023   },
    /* 3 */ { "TC3_96B_P32",      96,      32, CRC32_CASTAGNOLI },
    /* 4 */ { "TC4_192B_P64",    192,      64, CRC32_IEEE8023   },
    /* 5 */ { "TC5_512B",        512,       0, CRC32_CASTAGNOLI },
    /* 6 */ { "TC6_1KB_P128",   1024,     128, CRC32_IEEE8023   },
    /* 7 */ { "TC7_4KB",        4096,       0, CRC32_CASTAGNOLI },
    /* 8 */ { "TC8_64KB_P256", 65536,     256, CRC32_IEEE8023   },
    /* 9 */ { "TC9_1MB",     1048576,       0, CRC32_CASTAGNOLI },
};

// ---------------------------------------------------------------------------
// Generate counter-pattern plaintext used by all parameterised cases.
// pt[i] = (uint8_t)(i & 0xFF)  for i = 0 .. n_bytes-1
// ---------------------------------------------------------------------------
static inline void tc_gen_plaintext(uint8_t *pt, uint32_t n_bytes)
{
    uint32_t i;
    for (i = 0; i < n_bytes; i++)
        pt[i] = (uint8_t)(i & 0xFFu);
}

// ---------------------------------------------------------------------------
// Memory-layout helper (used by gen_mem.c and tb_top.v parameter computation).
//
// For a single-TC simulation memory image:
//   MEM_BASE  = 0x0000_1000
//   RING_BASE = MEM_BASE + 0x000  (1 descriptor, 32 B)
//   INBUF     = MEM_BASE + 0x100
//   inbuf_raw = 16 (header) + data + pad + 4 (CRC)  = data + pad + 20
//   inbuf_al  = align(inbuf_raw, 256)
//   OUTBUF    = MEM_BASE + 0x100 + inbuf_al
//   MEM_SIZE  = align(outbuf_offset + data + 256_slack, 8)
// ---------------------------------------------------------------------------
static inline void tc_compute_layout(uint32_t data, uint32_t pad,
                                     uint32_t mem_base,
                                     uint32_t *out_inbuf_base,
                                     uint32_t *out_outbuf_base,
                                     uint32_t *out_outbuf_off,
                                     uint32_t *out_mem_words)
{
    uint32_t inbuf_raw = 20u + data + pad;              /* 16+data+pad+4      */
    uint32_t inbuf_al  = (inbuf_raw + 255u) & ~255u;    /* align to 256 bytes */
    uint32_t outbuf_off = 0x100u + inbuf_al;
    uint32_t mem_sz    = ((outbuf_off + data + 255u) & ~255u) + 8u;
    mem_sz = (mem_sz + 7u) & ~7u;

    if (out_inbuf_base)   *out_inbuf_base  = mem_base + 0x100u;
    if (out_outbuf_base)  *out_outbuf_base = mem_base + outbuf_off;
    if (out_outbuf_off)   *out_outbuf_off  = outbuf_off;
    if (out_mem_words)    *out_mem_words   = mem_sz / 8u;
}

#endif /* TC_PARAMS_H */
