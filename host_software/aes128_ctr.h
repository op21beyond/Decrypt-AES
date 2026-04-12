// =============================================================================
// File        : aes128_ctr.h
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AES-128 CTR mode software implementation — interface.
//               Used for reference decryption and test-vector generation.
// =============================================================================

#ifndef AES128_CTR_H
#define AES128_CTR_H

#include <stddef.h>
#include <stdint.h>

// AES-128 context: 11 round keys of 16 bytes each (key schedule output).
typedef struct {
    uint8_t rk[11][16];
} aes128_ctx_t;

// Expand a 16-byte AES-128 key into the round key schedule stored in ctx.
void aes128_key_expand(aes128_ctx_t *ctx, const uint8_t key[16]);

// Encrypt a single 16-byte block (forward AES cipher).
// In CTR mode this is used for both encryption and decryption.
void aes128_encrypt_block(const aes128_ctx_t *ctx,
                          const uint8_t  in[16],
                          uint8_t       out[16]);

// CTR mode crypt (encrypt == decrypt).
//   nonce    : 12-byte nonce (bytes 0-11 of the AES counter block)
//   init_ctr : 32-bit initial counter value (big-endian in counter block,
//              bytes 12-15); matches AES Header bytes [15:12] in input buffer
//   in/out   : input and output byte arrays (may alias if in == out)
//   len      : number of bytes to process; need not be a multiple of 16
void aes128_ctr_crypt(const aes128_ctx_t *ctx,
                      const uint8_t       nonce[12],
                      uint32_t            init_ctr,
                      const uint8_t      *in,
                      uint8_t            *out,
                      size_t              len);

#endif // AES128_CTR_H
