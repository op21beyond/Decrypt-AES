// =============================================================================
// File        : sw_test.c
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Pure software reference test.
//               Validates the AES-128 CTR and CRC-32 implementations against
//               the NIST SP 800-38A F.5.1 test vectors, then exercises the
//               full input-buffer processing pipeline (header parse, CTR
//               decrypt, CRC verify) that mirrors what the IP hardware does.
//
//               Build:  gcc -O2 -Wall -o sw_test sw_test.c aes128_ctr.c crc32.c
//               Run:    ./sw_test
// =============================================================================

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "aes128_ctr.h"
#include "crc32.h"
#include "test_vectors.h"

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------
static void print_hex(const char *label, const uint8_t *buf, size_t len)
{
    printf("  %-20s: ", label);
    for (size_t i = 0; i < len; i++) {
        if (i && i % 16 == 0) printf("\n                        ");
        printf("%02x ", buf[i]);
    }
    printf("\n");
}

static int bytes_eq(const uint8_t *a, const uint8_t *b, size_t len)
{
    for (size_t i = 0; i < len; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

// ---------------------------------------------------------------------------
// Test 1 — AES-128 block encryption (single block, NIST vector)
// ---------------------------------------------------------------------------
static int test_aes_block(void)
{
    printf("[TEST 1] AES-128 block encrypt (NIST F.5.1, block 0)\n");

    // Counter block 1 from NIST: nonce || 0xFCFDFEFF
    const uint8_t ctr_block[16] = {
        0xf0,0xf1,0xf2,0xf3, 0xf4,0xf5,0xf6,0xf7,
        0xf8,0xf9,0xfa,0xfb, 0xfc,0xfd,0xfe,0xff
    };
    // Expected AES_Encrypt(key, ctr_block) = P0 XOR C0
    // C0 XOR P0:
    const uint8_t expected_ks[16] = {
        0x87^0x6b, 0x4d^0xc1, 0x61^0xbe, 0x91^0xe2,
        0xb6^0x2e, 0x20^0x40, 0xe3^0x9f, 0x26^0x96,
        0x1b^0xe9, 0xef^0x3d, 0x68^0x7e, 0x64^0x11,
        0x99^0x73, 0x0d^0x93, 0xb6^0x17, 0xce^0x2a
    };

    aes128_ctx_t ctx;
    aes128_key_expand(&ctx, TV_KEY);

    uint8_t ks[16];
    aes128_encrypt_block(&ctx, ctr_block, ks);

    print_hex("keystream", ks, 16);
    print_hex("expected",  expected_ks, 16);

    if (bytes_eq(ks, expected_ks, 16)) {
        printf("  PASS\n\n");
        return 0;
    }
    printf("  FAIL\n\n");
    return 1;
}

// ---------------------------------------------------------------------------
// Test 2 — AES-128 CTR decrypt (4-block NIST vector)
// ---------------------------------------------------------------------------
static int test_aes_ctr(void)
{
    printf("[TEST 2] AES-128 CTR decrypt (NIST F.5.1, 4 blocks)\n");

    aes128_ctx_t ctx;
    aes128_key_expand(&ctx, TV_KEY);

    uint8_t plaintext[64];
    aes128_ctr_crypt(&ctx, TV_NONCE, TV_INIT_CTR,
                     TV_CIPHERTEXT, plaintext, 64);

    print_hex("decrypted", plaintext, 64);
    print_hex("expected",  TV_PLAINTEXT, 64);

    if (bytes_eq(plaintext, TV_PLAINTEXT, 64)) {
        printf("  PASS\n\n");
        return 0;
    }
    printf("  FAIL\n\n");
    return 1;
}

// ---------------------------------------------------------------------------
// Test 3 — CRC-32 IEEE 802.3 ("123456789" golden value = 0xCBF43926)
// ---------------------------------------------------------------------------
static int test_crc32_ieee(void)
{
    printf("[TEST 3] CRC-32/IEEE 802.3 (\"123456789\" -> 0xCBF43926)\n");

    const uint8_t data[] = "123456789";
    uint32_t crc = crc32_compute(CRC32_IEEE8023, data, 9);

    printf("  computed : 0x%08X\n", crc);
    printf("  expected : 0xCBF43926\n");

    if (crc == 0xCBF43926u) {
        printf("  PASS\n\n");
        return 0;
    }
    printf("  FAIL\n\n");
    return 1;
}

// ---------------------------------------------------------------------------
// Test 4 — CRC-32C Castagnoli ("123456789" golden value = 0xE3069283)
// ---------------------------------------------------------------------------
static int test_crc32c(void)
{
    printf("[TEST 4] CRC-32C Castagnoli (\"123456789\" -> 0xE3069283)\n");

    const uint8_t data[] = "123456789";
    uint32_t crc = crc32_compute(CRC32_CASTAGNOLI, data, 9);

    printf("  computed : 0x%08X\n", crc);
    printf("  expected : 0xE3069283\n");

    if (crc == 0xE3069283u) {
        printf("  PASS\n\n");
        return 0;
    }
    printf("  FAIL\n\n");
    return 1;
}

// ---------------------------------------------------------------------------
// Full pipeline: parse input buffer, CTR decrypt, CRC verify
// Mirrors the processing sequence of the IP hardware.
// ---------------------------------------------------------------------------
typedef enum { JOB_OK = 0, JOB_CRC_ERR } job_result_t;

static job_result_t process_input_buf(const aes128_ctx_t *ctx,
                                      crc32_alg_t         crc_alg,
                                      const uint8_t      *inbuf,
                                      uint32_t            data_bytes,
                                      uint8_t            *outbuf)
{
    // 1. Parse AES Header: nonce (12 B) + initial counter big-endian (4 B)
    const uint8_t *nonce = inbuf;
    uint32_t init_ctr = ((uint32_t)inbuf[12] << 24) | ((uint32_t)inbuf[13] << 16)
                      | ((uint32_t)inbuf[14] <<  8) |  (uint32_t)inbuf[15];

    const uint8_t *ciphertext = inbuf + 16;

    // 2. Compute CRC-32 over ciphertext (parallel with decrypt in HW)
    uint32_t computed_crc = crc32_compute(crc_alg, ciphertext, data_bytes);

    // 3. AES-128 CTR decrypt: ciphertext -> plaintext
    aes128_ctr_crypt(ctx, nonce, init_ctr, ciphertext, outbuf, data_bytes);

    // 4. Read expected CRC from end of input buffer (after data + padding)
    //    For these test cases pad_bytes = 0.
    const uint8_t *crc_field = ciphertext + data_bytes; // pad_bytes omitted
    uint32_t expected_crc = (uint32_t)crc_field[0]
                          | ((uint32_t)crc_field[1] << 8)
                          | ((uint32_t)crc_field[2] << 16)
                          | ((uint32_t)crc_field[3] << 24);

    return (computed_crc == expected_crc) ? JOB_OK : JOB_CRC_ERR;
}

// ---------------------------------------------------------------------------
// Test 5/6 — Full pipeline for each test case
// ---------------------------------------------------------------------------
static int test_pipeline(uint32_t tc_idx)
{
    const tv_tc_t *tc = &TV_TC[tc_idx];
    printf("[TEST %u] Full pipeline: %s\n", 5u + tc_idx, tc->name);

    // Build the input buffer the same way the host SW would for the IP.
    size_t   inbuf_sz = tv_inbuf_size(tc_idx);
    uint8_t *inbuf    = (uint8_t *)malloc(inbuf_sz);
    uint8_t *outbuf   = (uint8_t *)malloc(tc->data_bytes);
    if (!inbuf || !outbuf) { free(inbuf); free(outbuf); return 1; }

    tv_build_inbuf(tc_idx, inbuf);

    aes128_ctx_t ctx;
    aes128_key_expand(&ctx, TV_KEY);

    job_result_t result = process_input_buf(&ctx, tc->crc_alg, inbuf,
                                            tc->data_bytes, outbuf);

    printf("  CRC check  : %s\n", (result == JOB_OK) ? "PASS" : "FAIL (unexpected)");

    int ok = (result == JOB_OK) &&
             bytes_eq(outbuf, TV_PLAINTEXT, tc->data_bytes);

    print_hex("decrypted", outbuf, tc->data_bytes);
    print_hex("expected",  TV_PLAINTEXT, tc->data_bytes);
    printf("  Overall    : %s\n\n", ok ? "PASS" : "FAIL");

    free(inbuf);
    free(outbuf);
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------------------
// Test 7 — CRC error injection: corrupt one byte of ciphertext
// ---------------------------------------------------------------------------
static int test_crc_error(void)
{
    printf("[TEST 7] CRC error detection (corrupted ciphertext)\n");

    size_t   inbuf_sz = tv_inbuf_size(0);
    uint8_t *inbuf    = (uint8_t *)malloc(inbuf_sz);
    uint8_t *outbuf   = (uint8_t *)malloc(TV_TC[0].data_bytes);
    if (!inbuf || !outbuf) { free(inbuf); free(outbuf); return 1; }

    tv_build_inbuf(0, inbuf);
    inbuf[16] ^= 0xFFu;  // flip all bits of the first ciphertext byte

    aes128_ctx_t ctx;
    aes128_key_expand(&ctx, TV_KEY);

    job_result_t result = process_input_buf(&ctx, TV_TC[0].crc_alg, inbuf,
                                            TV_TC[0].data_bytes, outbuf);

    int ok = (result == JOB_CRC_ERR);
    printf("  CRC check  : %s (error %s detected)\n",
           ok ? "PASS" : "FAIL",
           ok ? "correctly" : "NOT");
    printf("  Overall    : %s\n\n", ok ? "PASS" : "FAIL");

    free(inbuf);
    free(outbuf);
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void)
{
    printf("=============================================================\n");
    printf("  AES Decrypt IP — Pure Software Reference Test\n");
    printf("  NIST SP 800-38A F.5.1 (AES-128-CTR)\n");
    printf("=============================================================\n\n");

    int fail = 0;
    fail += test_aes_block();
    fail += test_aes_ctr();
    fail += test_crc32_ieee();
    fail += test_crc32c();
    fail += test_pipeline(0);
    fail += test_pipeline(1);
    fail += test_crc_error();

    printf("=============================================================\n");
    if (fail == 0)
        printf("  All tests PASSED\n");
    else
        printf("  %d test(s) FAILED\n", fail);
    printf("=============================================================\n");

    return (fail == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
