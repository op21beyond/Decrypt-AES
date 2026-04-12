// =============================================================================
// File        : gen_mem.c
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Generates mem_init.hex — the simulation memory image loaded by
//               fake_mem.v via $readmemh.
//
//               Memory layout (base = MEM_BASE):
//                 RING_BASE   +0x000  Descriptor ring (4 × 32 B = 128 B)
//                 INBUF0_BASE +0x100  Input buffer TC0  (4 blk, IEEE CRC)
//                 INBUF1_BASE +0x200  Input buffer TC1  (2 blk, CRC-32C)
//                 INBUF2_BASE +0x300  Input buffer TC2  (4 blk, CRC error)
//                 OUTBUF0_BASE+0x400  Output buffer TC0 (64 B, fill=0xCC)
//                 OUTBUF1_BASE+0x480  Output buffer TC1 (32 B, fill=0xCC)
//                 OUTBUF2_BASE+0x500  Output buffer TC2 (64 B, fill=0xCC)
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
// Test vector data (NIST SP 800-38A F.5.1)
// ---------------------------------------------------------------------------
static const uint8_t TV_KEY[16] = {
    0x2b,0x7e,0x15,0x16, 0x28,0xae,0xd2,0xa6,
    0xab,0xf7,0x15,0x88, 0x09,0xcf,0x4f,0x3c
};
static const uint8_t TV_NONCE[12] = {
    0xf0,0xf1,0xf2,0xf3, 0xf4,0xf5,0xf6,0xf7, 0xf8,0xf9,0xfa,0xfb
};
static const uint32_t TV_INIT_CTR = 0xFCFDFEFFu;

static const uint8_t TV_CIPHERTEXT[64] = {
    0x87,0x4d,0x61,0x91, 0xb6,0x20,0xe3,0x26, 0x1b,0xef,0x68,0x64, 0x99,0x0d,0xb6,0xce,
    0x98,0x06,0xf6,0x6b, 0x79,0x70,0xfd,0xff, 0x86,0x17,0x18,0x7b, 0xb9,0xff,0xfd,0xff,
    0x5a,0xe4,0xdf,0x3e, 0xdb,0xd5,0xd3,0x5e, 0x5b,0x4f,0x09,0x02, 0x0d,0xb0,0x3e,0xab,
    0x1e,0x03,0x1d,0xda, 0x2f,0xbe,0x03,0xd1, 0x79,0x21,0x70,0xa0, 0xf3,0x00,0x9c,0xee
};

// ---------------------------------------------------------------------------
// Memory layout parameters
// ---------------------------------------------------------------------------
#define MEM_BASE        0x00001000u
#define MEM_SIZE        0x00000800u  // 2 KB = 256 × 8-byte words
#define MEM_WORDS       (MEM_SIZE / 8)

#define RING_BASE       (MEM_BASE + 0x000u)
#define INBUF0_BASE     (MEM_BASE + 0x100u)  // TC0: 4 blk, IEEE  CRC
#define INBUF1_BASE     (MEM_BASE + 0x200u)  // TC1: 2 blk, CRC-32C
#define INBUF2_BASE     (MEM_BASE + 0x300u)  // TC2: 4 blk, IEEE  CRC (CRC error)
#define OUTBUF0_BASE    (MEM_BASE + 0x400u)  // 64 bytes
#define OUTBUF1_BASE    (MEM_BASE + 0x480u)  // 32 bytes
#define OUTBUF2_BASE    (MEM_BASE + 0x500u)  // 64 bytes

// Descriptor control byte fields
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
    mem_write8(addr + 1, (uint8_t)(val >> 8));
    mem_write8(addr + 2, (uint8_t)(val >> 16));
    mem_write8(addr + 3, (uint8_t)(val >> 24));
}

static void mem_write_bytes(uint32_t addr, const uint8_t *src, size_t n)
{
    for (size_t i = 0; i < n; i++) mem_write8(addr + (uint32_t)i, src[i]);
}

// ---------------------------------------------------------------------------
// Descriptor builder
// ---------------------------------------------------------------------------
static void write_descriptor(uint32_t desc_addr,
                             uint8_t  ctrl_flags,   // valid | interrupt | last
                             uint32_t in_addr,
                             uint32_t out_addr,
                             uint32_t in_data_bytes,
                             uint32_t in_pad_bytes,
                             uint32_t out_data_bytes,
                             uint32_t out_pad_bytes)
{
    // Header word: byte 0 = ctrl, byte 1 = state (0x00 = idle), bytes 2-3 = 0
    mem_write32_le(desc_addr + 0x00, (uint32_t)ctrl_flags);
    mem_write32_le(desc_addr + 0x04, in_addr);
    mem_write32_le(desc_addr + 0x08, out_addr);
    mem_write32_le(desc_addr + 0x0C, (in_data_bytes & 0x00FFFFFFu) |
                                     ((in_pad_bytes & 0xFFu) << 24));
    mem_write32_le(desc_addr + 0x10, (out_data_bytes & 0x00FFFFFFu) |
                                     ((out_pad_bytes & 0xFFu) << 24));
    // Reserved bytes 0x14-0x1F = 0 (already zero from memset)
}

// ---------------------------------------------------------------------------
// Input buffer builder
// Input layout: AES header (16B) | ciphertext (N B) | padding (M B) | CRC (4B)
// ---------------------------------------------------------------------------
static void write_inbuf(uint32_t buf_addr,
                        const uint8_t *ciphertext, uint32_t n_bytes,
                        uint32_t pad_bytes,
                        crc32_alg_t crc_alg)
{
    // AES header: nonce (12 B) + initial counter big-endian (4 B)
    mem_write_bytes(buf_addr, TV_NONCE, 12);
    mem_write8(buf_addr + 12, (uint8_t)(TV_INIT_CTR >> 24));
    mem_write8(buf_addr + 13, (uint8_t)(TV_INIT_CTR >> 16));
    mem_write8(buf_addr + 14, (uint8_t)(TV_INIT_CTR >>  8));
    mem_write8(buf_addr + 15, (uint8_t)(TV_INIT_CTR));

    // Ciphertext
    mem_write_bytes(buf_addr + 16, ciphertext, n_bytes);

    // Padding (already 0x00 from memset)
    (void)pad_bytes;

    // CRC-32 (little-endian) over ciphertext only
    uint32_t crc = crc32_compute(crc_alg, ciphertext, n_bytes);
    uint32_t crc_off = buf_addr + 16 + n_bytes + pad_bytes;
    mem_write8(crc_off + 0, (uint8_t)(crc));
    mem_write8(crc_off + 1, (uint8_t)(crc >> 8));
    mem_write8(crc_off + 2, (uint8_t)(crc >> 16));
    mem_write8(crc_off + 3, (uint8_t)(crc >> 24));

    printf("  inbuf @ 0x%08X : %u data bytes, pad=%u, CRC=0x%08X (%s)\n",
           buf_addr, n_bytes, pad_bytes, crc,
           (crc_alg == CRC32_IEEE8023) ? "IEEE 802.3" : "Castagnoli");
}

// ---------------------------------------------------------------------------
// Output hex file
// ---------------------------------------------------------------------------
static void dump_hex(const char *filename)
{
    FILE *f = fopen(filename, "w");
    if (!f) { perror(filename); exit(1); }

    // One 64-bit word per line (big-endian byte order within the word)
    for (uint32_t w = 0; w < MEM_WORDS; w++) {
        uint32_t off = w * 8;
        fprintf(f, "%02x%02x%02x%02x%02x%02x%02x%02x\n",
                mem[off+7], mem[off+6], mem[off+5], mem[off+4],
                mem[off+3], mem[off+2], mem[off+1], mem[off+0]);
    }
    fclose(f);
    printf("  Written: %s (%u words × 8 bytes)\n", filename, MEM_WORDS);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void)
{
    printf("=== gen_mem: AES Decrypt IP testbench memory generator ===\n\n");

    memset(mem, 0x00, sizeof(mem));

    // Pre-fill output buffer regions with 0xCC (canary) so we can detect
    // correct writes vs. un-touched bytes.
    memset(mem + (OUTBUF0_BASE - MEM_BASE), 0xCC, 64);
    memset(mem + (OUTBUF1_BASE - MEM_BASE), 0xCC, 32);
    memset(mem + (OUTBUF2_BASE - MEM_BASE), 0xCC, 64);

    // ------------------------------------------------------------------
    // Input buffers
    // ------------------------------------------------------------------
    printf("[INBUF]\n");

    // TC0: 4 blocks, CRC-32/IEEE 802.3
    write_inbuf(INBUF0_BASE, TV_CIPHERTEXT, 64, 0, CRC32_IEEE8023);

    // TC1: first 2 blocks, CRC-32C
    write_inbuf(INBUF1_BASE, TV_CIPHERTEXT, 32, 0, CRC32_CASTAGNOLI);

    // TC2: 4 blocks with first ciphertext byte corrupted.
    // Stored CRC = CRC-32C over ORIGINAL ciphertext (CRC_CTRL will be Castagnoli
    // when Desc 2 is processed).  IP computes CRC over corrupted data → mismatch.
    uint8_t corrupted[64];
    memcpy(corrupted, TV_CIPHERTEXT, 64);
    corrupted[0] ^= 0xFFu;  // flip all bits of byte 0
    write_inbuf(INBUF2_BASE, corrupted, 64, 0, CRC32_CASTAGNOLI);
    // Overwrite CRC field with Castagnoli over ORIGINAL (not corrupted) data
    uint32_t good_crc = crc32_compute(CRC32_CASTAGNOLI, TV_CIPHERTEXT, 64);
    uint32_t crc_off  = INBUF2_BASE + 16 + 64; // no padding
    mem_write8(crc_off + 0, (uint8_t)(good_crc));
    mem_write8(crc_off + 1, (uint8_t)(good_crc >> 8));
    mem_write8(crc_off + 2, (uint8_t)(good_crc >> 16));
    mem_write8(crc_off + 3, (uint8_t)(good_crc >> 24));
    printf("  inbuf2 CRC field = CRC-32C over original = 0x%08X "
           "(ciphertext is corrupted -> HW CRC mismatch)\n", good_crc);

    // ------------------------------------------------------------------
    // Descriptor ring
    // ------------------------------------------------------------------
    printf("\n[DESCRIPTORS]\n");

    // Desc 0: TC0 — 4 blocks, interrupt=1 (host changes CRC_CTRL during PAUSE)
    write_descriptor(RING_BASE + 0*32,
                     DESC_VALID | DESC_INTERRUPT,
                     INBUF0_BASE, OUTBUF0_BASE,
                     64, 0, 64, 0);
    printf("  Desc 0 @ 0x%08X : TC0 (4blk, irq, not-last)\n",
           RING_BASE + 0*32);

    // Desc 1: TC1 — 2 blocks, interrupt=1, last=0  (more follow after resume)
    write_descriptor(RING_BASE + 1*32,
                     DESC_VALID | DESC_INTERRUPT,
                     INBUF1_BASE, OUTBUF1_BASE,
                     32, 0, 32, 0);
    printf("  Desc 1 @ 0x%08X : TC1 (2blk, irq,    not-last)\n",
           RING_BASE + 1*32);

    // Desc 2: TC2 — CRC error, no interrupt, last=1
    write_descriptor(RING_BASE + 2*32,
                     DESC_VALID | DESC_LAST,
                     INBUF2_BASE, OUTBUF2_BASE,
                     64, 0, 64, 0);
    printf("  Desc 2 @ 0x%08X : TC2 (4blk, crc-err, last)\n",
           RING_BASE + 2*32);

    // Desc 3: unused (valid=0)
    printf("  Desc 3 @ 0x%08X : unused (valid=0)\n", RING_BASE + 3*32);

    // ------------------------------------------------------------------
    // Print memory map summary
    // ------------------------------------------------------------------
    printf("\n[MEMORY MAP]\n");
    printf("  Ring    : 0x%08X\n", RING_BASE);
    printf("  Inbuf0  : 0x%08X  (TC0 in)\n",  INBUF0_BASE);
    printf("  Inbuf1  : 0x%08X  (TC1 in)\n",  INBUF1_BASE);
    printf("  Inbuf2  : 0x%08X  (TC2 in)\n",  INBUF2_BASE);
    printf("  Outbuf0 : 0x%08X  (TC0 out)\n", OUTBUF0_BASE);
    printf("  Outbuf1 : 0x%08X  (TC1 out)\n", OUTBUF1_BASE);
    printf("  Outbuf2 : 0x%08X  (TC2 out)\n", OUTBUF2_BASE);

    // ------------------------------------------------------------------
    // Dump hex
    // ------------------------------------------------------------------
    printf("\n[OUTPUT]\n");
    dump_hex("mem_init.hex");

    printf("\nDone.\n");
    return 0;
}
