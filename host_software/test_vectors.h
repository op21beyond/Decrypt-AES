// =============================================================================
// File        : test_vectors.h
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Shared test vectors used by sw_test.c and ip_test.c.
//
//               Source: NIST SP 800-38A, Appendix F.5.1
//                       AES-128-CTR, 4-block (64-byte) example
//
//               Two test cases are defined:
//                 TC0 — 4 blocks (64 B), interrupt=0, last=0
//                 TC1 — 2 blocks (32 B), interrupt=1, last=1
//               (TC1 uses the first two blocks of the NIST vector.)
//
// Input buffer memory layout (at IN_ADDR):
//   [0 .. 15]            : AES Header  (nonce[11:0] + init_ctr BE32)
//   [16 .. 16+N-1]       : Ciphertext  (N = IN_DATA_SIZE bytes)
//   [16+N .. 16+N+M-1]   : Padding     (M = IN_PAD_SIZE bytes, if any)
//   [16+N+M .. 16+N+M+3] : CRC-32      (little-endian, over ciphertext only)
// =============================================================================

#ifndef TEST_VECTORS_H
#define TEST_VECTORS_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "crc32.h"

// ---------------------------------------------------------------------------
// NIST SP 800-38A F.5.1 — AES-128 key
// ---------------------------------------------------------------------------
static const uint8_t TV_KEY[16] = {
    0x2b,0x7e,0x15,0x16, 0x28,0xae,0xd2,0xa6,
    0xab,0xf7,0x15,0x88, 0x09,0xcf,0x4f,0x3c
};

// Nonce: bytes [11:0] of the AES counter block (12 bytes)
static const uint8_t TV_NONCE[12] = {
    0xf0,0xf1,0xf2,0xf3, 0xf4,0xf5,0xf6,0xf7, 0xf8,0xf9,0xfa,0xfb
};

// Initial counter value: bytes [15:12] of counter block, big-endian in block.
// NIST counter block 1: ...FC FD FE FF → init_ctr = 0xFCFDFEFF
#define TV_INIT_CTR  0xFCFDFEFFu

// ---------------------------------------------------------------------------
// Known-good plaintext (4 blocks × 16 bytes = 64 bytes)
// ---------------------------------------------------------------------------
static const uint8_t TV_PLAINTEXT[64] = {
    // Block 0
    0x6b,0xc1,0xbe,0xe2, 0x2e,0x40,0x9f,0x96, 0xe9,0x3d,0x7e,0x11, 0x73,0x93,0x17,0x2a,
    // Block 1
    0xae,0x2d,0x8a,0x57, 0x1e,0x03,0xac,0x9c, 0x9e,0xb7,0x6f,0xac, 0x45,0xaf,0x8e,0x51,
    // Block 2
    0x30,0xc8,0x1c,0x46, 0xa3,0x5c,0xe4,0x11, 0xe5,0xfb,0xc1,0x19, 0x1a,0x0a,0x52,0xef,
    // Block 3
    0xf6,0x9f,0x24,0x45, 0xdf,0x4f,0x9b,0x17, 0xad,0x2b,0x41,0x7b, 0xe6,0x6c,0x37,0x10
};

// ---------------------------------------------------------------------------
// Known-good ciphertext (NIST F.5.1)
// ---------------------------------------------------------------------------
static const uint8_t TV_CIPHERTEXT[64] = {
    // Block 0
    0x87,0x4d,0x61,0x91, 0xb6,0x20,0xe3,0x26, 0x1b,0xef,0x68,0x64, 0x99,0x0d,0xb6,0xce,
    // Block 1
    0x98,0x06,0xf6,0x6b, 0x79,0x70,0xfd,0xff, 0x86,0x17,0x18,0x7b, 0xb9,0xff,0xfd,0xff,
    // Block 2
    0x5a,0xe4,0xdf,0x3e, 0xdb,0xd5,0xd3,0x5e, 0x5b,0x4f,0x09,0x02, 0x0d,0xb0,0x3e,0xab,
    // Block 3
    0x1e,0x03,0x1d,0xda, 0x2f,0xbe,0x03,0xd1, 0x79,0x21,0x70,0xa0, 0xf3,0x00,0x9c,0xee
};

// ---------------------------------------------------------------------------
// Test case descriptor
// ---------------------------------------------------------------------------
typedef struct {
    const char *name;
    uint32_t    data_bytes;     // IN_DATA_SIZE = OUT_DATA_SIZE (no stripping)
    uint32_t    pad_bytes;      // IN_PAD_SIZE
    int         interrupt;      // descriptor interrupt flag
    int         last;           // descriptor last flag
    crc32_alg_t crc_alg;       // CRC algorithm for this test case
} tv_tc_t;

// TC0: 4 blocks, no interrupt, not the last descriptor
// TC1: first 2 blocks, interrupt and last
static const tv_tc_t TV_TC[] = {
    { "TC0_4blk_noirq",  64, 0, 0, 0, CRC32_IEEE8023   },
    { "TC1_2blk_irq",    32, 0, 1, 1, CRC32_CASTAGNOLI }
};
#define TV_TC_COUNT  2u

// ---------------------------------------------------------------------------
// Input buffer builder
// ---------------------------------------------------------------------------
// Fills buf[] with the complete input buffer for test case tc_idx:
//   AES Header | Ciphertext | Padding(0x00) | CRC-32 (LE)
// buf must be at least tv_inbuf_size(tc_idx) bytes.
// Returns total size in bytes.
static inline size_t tv_inbuf_size(uint32_t tc_idx)
{
    return 16u + TV_TC[tc_idx].data_bytes
               + TV_TC[tc_idx].pad_bytes
               + 4u;
}

static inline size_t tv_build_inbuf(uint32_t tc_idx, uint8_t *buf)
{
    const tv_tc_t *tc = &TV_TC[tc_idx];

    // AES Header: nonce (12 B) + initial counter big-endian (4 B)
    memcpy(buf, TV_NONCE, 12);
    buf[12] = (uint8_t)(TV_INIT_CTR >> 24);
    buf[13] = (uint8_t)(TV_INIT_CTR >> 16);
    buf[14] = (uint8_t)(TV_INIT_CTR >>  8);
    buf[15] = (uint8_t)(TV_INIT_CTR);

    // Ciphertext
    memcpy(buf + 16, TV_CIPHERTEXT, tc->data_bytes);

    // Padding (written as 0x00)
    memset(buf + 16 + tc->data_bytes, 0x00, tc->pad_bytes);

    // CRC-32 over ciphertext only (little-endian)
    uint32_t crc = crc32_compute(tc->crc_alg, TV_CIPHERTEXT, tc->data_bytes);
    uint32_t off = 16u + tc->data_bytes + tc->pad_bytes;
    buf[off + 0] = (uint8_t)(crc);
    buf[off + 1] = (uint8_t)(crc >> 8);
    buf[off + 2] = (uint8_t)(crc >> 16);
    buf[off + 3] = (uint8_t)(crc >> 24);

    return off + 4u;
}

#endif // TEST_VECTORS_H
