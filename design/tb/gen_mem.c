// =============================================================================
// File        : gen_mem.c
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Generates mem_init.hex — the simulation memory image loaded by
//               fake_mem.v via $readmemh.
//
//               Four test cases cover diverse data sizes, padding sizes,
//               and both CRC algorithms.  All use the same NIST key/nonce.
//               Plaintext pattern: pt[i] = (uint8_t)(i & 0xFF).
//
//               Memory layout (base = 0x0000_1000):
//                 RING_BASE (+0x000) : 4 × 32 B descriptors
//                 INBUF0    (+0x100) : TC0  16 B data,  0 B pad, IEEE
//                 INBUF1    (+0x200) : TC1  48 B data, 16 B pad, CRC-32C
//                 INBUF2    (+0x300) : TC2  96 B data, 32 B pad, IEEE
//                 INBUF3    (+0x500) : TC3  48 B data,  8 B pad, CRC-32C (CRC err)
//                 OUTBUF0   (+0x600) : TC0 out  16 B (pre-fill 0xCC)
//                 OUTBUF1   (+0x640) : TC1 out  48 B (pre-fill 0xCC)
//                 OUTBUF2   (+0x700) : TC2 out  96 B (pre-fill 0xCC)
//                 OUTBUF3   (+0x780) : TC3 out  48 B (pre-fill 0xCC; CRC err)
//
//               Descriptor flags:
//                 Desc 0 (TC0): valid, interrupt=1          → PAUSE
//                 Desc 1 (TC1): valid, interrupt=1          → PAUSE
//                 Desc 2 (TC2): valid, interrupt=1          → PAUSE
//                 Desc 3 (TC3): valid, last=1               → STOP + CRC_ERR
//
//               Ring wrap-around: TB sets tail=0 (wraps past slot 3) when
//               submitting TC3, so head wraps 3→0 after TC3 finishes.
//
//               Build & run from design/tb/:
//                 gcc -O2 -o gen_mem gen_mem.c ../../host_software/aes128_ctr.c \
//                     ../../host_software/crc32.c -I../../host_software
//                 ./gen_mem
//               Output: mem_init.hex  (one 64-bit word per line, no-address format)
// =============================================================================

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "aes128_ctr.h"
#include "crc32.h"

// ---------------------------------------------------------------------------
// NIST SP 800-38A F.5.1 key and nonce (shared by all TCs)
// ---------------------------------------------------------------------------
static const uint8_t TV_KEY[16] = {
    0x2b,0x7e,0x15,0x16, 0x28,0xae,0xd2,0xa6,
    0xab,0xf7,0x15,0x88, 0x09,0xcf,0x4f,0x3c
};
static const uint8_t TV_NONCE[12] = {
    0xf0,0xf1,0xf2,0xf3, 0xf4,0xf5,0xf6,0xf7, 0xf8,0xf9,0xfa,0xfb
};
static const uint32_t TV_INIT_CTR = 0xFCFDFEFFu;

// ---------------------------------------------------------------------------
// Memory layout
// ---------------------------------------------------------------------------
#define MEM_BASE        0x00001000u
#define MEM_SIZE        0x00001000u  // 4 KB = 512 × 8-byte words
#define MEM_WORDS       (MEM_SIZE / 8u)

#define RING_BASE       (MEM_BASE + 0x000u)

#define INBUF0_BASE     (MEM_BASE + 0x100u)  // TC0: 16B data,  0B pad, IEEE
#define INBUF1_BASE     (MEM_BASE + 0x200u)  // TC1: 48B data, 16B pad, CRC-32C
#define INBUF2_BASE     (MEM_BASE + 0x300u)  // TC2: 96B data, 32B pad, IEEE
#define INBUF3_BASE     (MEM_BASE + 0x500u)  // TC3: 48B data,  8B pad, CRC-32C (CRC err)

#define OUTBUF0_BASE    (MEM_BASE + 0x600u)  // TC0 out: 16B
#define OUTBUF1_BASE    (MEM_BASE + 0x640u)  // TC1 out: 48B
#define OUTBUF2_BASE    (MEM_BASE + 0x700u)  // TC2 out: 96B
#define OUTBUF3_BASE    (MEM_BASE + 0x780u)  // TC3 out: 48B (CRC err; still written)

// Descriptor field macros
#define DESC_VALID      (1u << 0)
#define DESC_INTERRUPT  (1u << 1)
#define DESC_LAST       (1u << 2)

// ---------------------------------------------------------------------------
// Memory array (byte-addressed relative to MEM_BASE)
// ---------------------------------------------------------------------------
static uint8_t mem[MEM_SIZE];

static void mem_write8(uint32_t addr, uint8_t val)
{
    uint32_t off = addr - MEM_BASE;
    if (off < MEM_SIZE) mem[off] = val;
}

static void mem_write32_le(uint32_t addr, uint32_t val)
{
    mem_write8(addr + 0, (uint8_t)(val));
    mem_write8(addr + 1, (uint8_t)(val >>  8));
    mem_write8(addr + 2, (uint8_t)(val >> 16));
    mem_write8(addr + 3, (uint8_t)(val >> 24));
}

static void mem_write_bytes(uint32_t addr, const uint8_t *src, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++) mem_write8(addr + (uint32_t)i, src[i]);
}

// ---------------------------------------------------------------------------
// Descriptor builder
// ---------------------------------------------------------------------------
static void write_descriptor(uint32_t desc_addr,
                             uint8_t  ctrl_flags,
                             uint32_t in_addr,
                             uint32_t out_addr,
                             uint32_t in_data_bytes,
                             uint32_t in_pad_bytes,
                             uint32_t out_data_bytes,
                             uint32_t out_pad_bytes)
{
    mem_write32_le(desc_addr + 0x00, (uint32_t)ctrl_flags);
    mem_write32_le(desc_addr + 0x04, in_addr);
    mem_write32_le(desc_addr + 0x08, out_addr);
    mem_write32_le(desc_addr + 0x0C, (in_data_bytes  & 0x00FFFFFFu) |
                                     ((in_pad_bytes  & 0xFFu) << 24));
    mem_write32_le(desc_addr + 0x10, (out_data_bytes & 0x00FFFFFFu) |
                                     ((out_pad_bytes & 0xFFu) << 24));
    // bytes 0x14-0x1F: reserved, left zero
}

// ---------------------------------------------------------------------------
// Input buffer builder
// Input layout: AES header (16B) | ciphertext (N B) | padding (M B) | CRC (4B)
// Plaintext: counter pattern pt[i] = i & 0xFF
// ---------------------------------------------------------------------------
static void write_inbuf(uint32_t buf_addr,
                        uint32_t data_bytes,
                        uint32_t pad_bytes,
                        crc32_alg_t crc_alg,
                        int corrupt_first_byte)   // non-zero: flip byte 0 of ciphertext
{
    aes128_ctx_t ctx;
    uint8_t plaintext[96];  // enough for largest TC (96 B)
    uint8_t ciphertext[96];
    uint32_t i;
    uint32_t crc;

    // Generate counter-pattern plaintext
    for (i = 0; i < data_bytes; i++)
        plaintext[i] = (uint8_t)(i & 0xFFu);

    // Encrypt with AES-128-CTR
    aes128_key_expand(&ctx, TV_KEY);
    aes128_ctr_crypt(&ctx, TV_NONCE, TV_INIT_CTR, plaintext, ciphertext, data_bytes);

    // Write AES header: nonce (12 B) + initial counter big-endian (4 B)
    mem_write_bytes(buf_addr, TV_NONCE, 12);
    mem_write8(buf_addr + 12, (uint8_t)(TV_INIT_CTR >> 24));
    mem_write8(buf_addr + 13, (uint8_t)(TV_INIT_CTR >> 16));
    mem_write8(buf_addr + 14, (uint8_t)(TV_INIT_CTR >>  8));
    mem_write8(buf_addr + 15, (uint8_t)(TV_INIT_CTR));

    // Optionally corrupt first ciphertext byte (for CRC-error TC)
    if (corrupt_first_byte)
        ciphertext[0] ^= 0xFFu;

    // Write ciphertext
    mem_write_bytes(buf_addr + 16, ciphertext, data_bytes);

    // Padding bytes are 0x00 (already zeroed by memset)

    // CRC over the ORIGINAL (pre-corruption) ciphertext
    if (corrupt_first_byte)
        ciphertext[0] ^= 0xFFu;  // restore for CRC calculation
    crc = crc32_compute(crc_alg, ciphertext, data_bytes);
    {
        uint32_t crc_off = buf_addr + 16u + data_bytes + pad_bytes;
        mem_write8(crc_off + 0, (uint8_t)(crc));
        mem_write8(crc_off + 1, (uint8_t)(crc >>  8));
        mem_write8(crc_off + 2, (uint8_t)(crc >> 16));
        mem_write8(crc_off + 3, (uint8_t)(crc >> 24));
    }

    printf("  inbuf @ 0x%08X : %3u data bytes, pad=%2u, CRC=0x%08X (%s)%s\n",
           buf_addr, data_bytes, pad_bytes, crc,
           (crc_alg == CRC32_IEEE8023) ? "IEEE 802.3" : "CRC-32C",
           corrupt_first_byte ? "  ← ciphertext corrupted (CRC mismatch expected)" : "");
}

// ---------------------------------------------------------------------------
// Dump hex file
// ---------------------------------------------------------------------------
static void dump_hex(const char *filename)
{
    FILE *f = fopen(filename, "w");
    uint32_t w;
    if (!f) { perror(filename); exit(1); }

    for (w = 0; w < MEM_WORDS; w++) {
        uint32_t off = w * 8;
        fprintf(f, "%02x%02x%02x%02x%02x%02x%02x%02x\n",
                mem[off+7], mem[off+6], mem[off+5], mem[off+4],
                mem[off+3], mem[off+2], mem[off+1], mem[off+0]);
    }
    fclose(f);
    printf("  Written: %s (%u words × 8 bytes = %u KB)\n",
           filename, (unsigned)MEM_WORDS, (unsigned)(MEM_SIZE / 1024));
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void)
{
    printf("=== gen_mem: AES Decrypt IP testbench memory generator ===\n\n");
    memset(mem, 0x00, sizeof(mem));

    // Pre-fill output buffers with 0xCC so un-written bytes are visible
    memset(mem + (OUTBUF0_BASE - MEM_BASE), 0xCC, 16u);
    memset(mem + (OUTBUF1_BASE - MEM_BASE), 0xCC, 48u);
    memset(mem + (OUTBUF2_BASE - MEM_BASE), 0xCC, 96u);
    memset(mem + (OUTBUF3_BASE - MEM_BASE), 0xCC, 48u);

    // ------------------------------------------------------------------
    // Input buffers
    // ------------------------------------------------------------------
    printf("[INBUF]\n");

    // TC0: 16 B data (1 AES block), 0 B pad, IEEE 802.3
    write_inbuf(INBUF0_BASE, 16, 0, CRC32_IEEE8023, 0);

    // TC1: 48 B data (3 AES blocks), 16 B pad, CRC-32C
    write_inbuf(INBUF1_BASE, 48, 16, CRC32_CASTAGNOLI, 0);

    // TC2: 96 B data (6 AES blocks), 32 B pad, IEEE 802.3
    write_inbuf(INBUF2_BASE, 96, 32, CRC32_IEEE8023, 0);

    // TC3: 48 B data (3 AES blocks), 8 B pad, CRC-32C
    // First ciphertext byte corrupted; CRC stored over original → CRC mismatch
    write_inbuf(INBUF3_BASE, 48, 8, CRC32_CASTAGNOLI, 1);

    // ------------------------------------------------------------------
    // Descriptor ring
    // ------------------------------------------------------------------
    printf("\n[DESCRIPTORS]\n");

    // Desc 0: TC0 — 16B data, 0B pad, interrupt=1 → PAUSE (host changes CRC alg)
    write_descriptor(RING_BASE + 0*32,
                     DESC_VALID | DESC_INTERRUPT,
                     INBUF0_BASE, OUTBUF0_BASE,
                     16, 0, 16, 0);
    printf("  Desc 0 @ 0x%08X : TC0 (1blk,  irq, not-last)\n", RING_BASE + 0*32);

    // Desc 1: TC1 — 48B data, 16B pad, interrupt=1 → PAUSE
    write_descriptor(RING_BASE + 1*32,
                     DESC_VALID | DESC_INTERRUPT,
                     INBUF1_BASE, OUTBUF1_BASE,
                     48, 16, 48, 0);
    printf("  Desc 1 @ 0x%08X : TC1 (3blk, 16B pad, irq, not-last)\n",
           RING_BASE + 1*32);

    // Desc 2: TC2 — 96B data, 32B pad, interrupt=1 → PAUSE
    write_descriptor(RING_BASE + 2*32,
                     DESC_VALID | DESC_INTERRUPT,
                     INBUF2_BASE, OUTBUF2_BASE,
                     96, 32, 96, 0);
    printf("  Desc 2 @ 0x%08X : TC2 (6blk, 32B pad, irq, not-last)\n",
           RING_BASE + 2*32);

    // Desc 3: TC3 — 48B data, 8B pad, CRC error, last=1 → STOP + CRC_ERR
    // TB sets tail=0 (wraps past slot 3) to exercise head-pointer wrap-around.
    write_descriptor(RING_BASE + 3*32,
                     DESC_VALID | DESC_LAST,
                     INBUF3_BASE, OUTBUF3_BASE,
                     48, 8, 48, 0);
    printf("  Desc 3 @ 0x%08X : TC3 (3blk,  8B pad, crc-err, last) [wrap slot]\n",
           RING_BASE + 3*32);

    // ------------------------------------------------------------------
    // Memory map summary
    // ------------------------------------------------------------------
    printf("\n[MEMORY MAP]\n");
    printf("  Ring    : 0x%08X  (4 × 32 B)\n", RING_BASE);
    printf("  Inbuf0  : 0x%08X  TC0  16B data,  0B pad, IEEE\n",  INBUF0_BASE);
    printf("  Inbuf1  : 0x%08X  TC1  48B data, 16B pad, CRC-32C\n", INBUF1_BASE);
    printf("  Inbuf2  : 0x%08X  TC2  96B data, 32B pad, IEEE\n",  INBUF2_BASE);
    printf("  Inbuf3  : 0x%08X  TC3  48B data,  8B pad, CRC-32C (corrupted)\n", INBUF3_BASE);
    printf("  Outbuf0 : 0x%08X  TC0 out 16B\n", OUTBUF0_BASE);
    printf("  Outbuf1 : 0x%08X  TC1 out 48B\n", OUTBUF1_BASE);
    printf("  Outbuf2 : 0x%08X  TC2 out 96B\n", OUTBUF2_BASE);
    printf("  Outbuf3 : 0x%08X  TC3 out 48B (CRC err — still written)\n", OUTBUF3_BASE);
    printf("  Total   : 0x%08X bytes = %u KB\n", MEM_SIZE, MEM_SIZE / 1024u);

    printf("\n[OUTPUT]\n");
    dump_hex("mem_init.hex");

    printf("\nDone.\n");
    return 0;
}
