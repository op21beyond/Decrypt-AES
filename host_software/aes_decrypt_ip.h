// =============================================================================
// File        : aes_decrypt_ip.h
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AES Decrypt IP driver — register map, descriptor format,
//               and driver API.
//
//               Register base address is supplied by the caller at init time.
//               All register accesses go through platform-provided callbacks
//               (reg_read / reg_write) stored in aes_ip_ctx_t, so the driver
//               is portable across bare-metal, RTOS, and simulation
//               environments.
// =============================================================================

#ifndef AES_DECRYPT_IP_H
#define AES_DECRYPT_IP_H

#include <stdint.h>
#include <stddef.h>

// ---------------------------------------------------------------------------
// Register offsets (byte addresses relative to IP base)
// ---------------------------------------------------------------------------
#define AES_IP_REG_CTRL             0x00u
#define AES_IP_REG_STATUS           0x04u
#define AES_IP_REG_IRQ_STATUS       0x08u
#define AES_IP_REG_IRQ_ENABLE       0x0Cu
#define AES_IP_REG_CMD_BUF_ADDR     0x10u
#define AES_IP_REG_CMD_BUF_SIZE     0x14u
#define AES_IP_REG_CMD_HEAD_PTR     0x18u
#define AES_IP_REG_CMD_TAIL_PTR     0x1Cu
#define AES_IP_REG_AES_KEY_0        0x20u
#define AES_IP_REG_AES_KEY_1        0x24u
#define AES_IP_REG_AES_KEY_2        0x28u
#define AES_IP_REG_AES_KEY_3        0x2Cu
#define AES_IP_REG_CRC_CTRL         0x30u
#define AES_IP_REG_AXI_OUTSTAND     0x34u
#define AES_IP_REG_AXI_CACHE_CTRL   0x38u
#define AES_IP_REG_AXI_PROT_CTRL    0x3Cu
#define AES_IP_REG_INTERVAL         0x40u

// ---------------------------------------------------------------------------
// CTRL register — self-clearing pulse bits (write 1 to trigger)
// ---------------------------------------------------------------------------
#define AES_IP_CTRL_START           (1u << 0)
#define AES_IP_CTRL_RESUME          (1u << 1)
#define AES_IP_CTRL_IMMEDIATE_STOP  (1u << 2)

// ---------------------------------------------------------------------------
// STATUS register
// ---------------------------------------------------------------------------
#define AES_IP_STATUS_STATE_MASK    0x03u       // bits [1:0]
#define AES_IP_STATUS_BUS_ERROR     (1u << 2)   // W1C

// STATUS.STATE encodings
#define AES_IP_STATE_STOP           0x00u
#define AES_IP_STATE_ACTIVE         0x01u
#define AES_IP_STATE_PAUSE          0x02u

// ---------------------------------------------------------------------------
// IRQ_STATUS / IRQ_ENABLE register bits
// ---------------------------------------------------------------------------
#define AES_IP_IRQ_DESCRIPTOR_DONE  (1u << 0)
#define AES_IP_IRQ_BUS_ERROR        (1u << 1)

// ---------------------------------------------------------------------------
// AXI_OUTSTAND register fields
// ---------------------------------------------------------------------------
#define AES_IP_OUTSTAND_RD_SHIFT    0           // bits [4:0]
#define AES_IP_OUTSTAND_WR_SHIFT    5           // bits [9:5]
#define AES_IP_OUTSTAND_MASK        0x1Fu

// ---------------------------------------------------------------------------
// CRC_CTRL register
// ---------------------------------------------------------------------------
#define AES_IP_CRC_ALG_IEEE8023     0u
#define AES_IP_CRC_ALG_CASTAGNOLI   1u

// ---------------------------------------------------------------------------
// Descriptor structure (32 bytes, little-endian)
// ---------------------------------------------------------------------------
// Must be placed in memory at a 32-byte aligned address.  All pointer and
// size fields are little-endian on the bus.
//
// header_word layout:
//   Byte 0 (control — written by host):
//     [0]   valid      : 1 = descriptor ready; IP clears to 0 on completion
//     [1]   interrupt  : 1 = assert IRQ and enter PAUSE on completion
//     [2]   last       : 1 = transition to STOP after this descriptor
//     [7:3] reserved
//   Byte 1 (state — written by IP):
//     result code (see DESC_STATE_* below)
//   Bytes 2-3: reserved

typedef struct {
    uint32_t header_word;   // control flags (byte 0) + state byte (byte 1)
    uint32_t in_addr;       // input buffer byte address
    uint32_t out_addr;      // output buffer byte address
    uint32_t in_size;       // [23:0]=IN_DATA_SIZE bytes, [31:24]=IN_PAD_SIZE
    uint32_t out_size;      // [23:0]=OUT_DATA_SIZE bytes,[31:24]=OUT_PAD_SIZE
    uint32_t reserved[3];
} aes_ip_desc_t;

// Header word control-byte bit masks
#define DESC_CTRL_VALID             (1u << 0)
#define DESC_CTRL_INTERRUPT         (1u << 1)
#define DESC_CTRL_LAST              (1u << 2)

// State byte (bits [15:8] of header_word) — written by IP
#define DESC_STATE_SHIFT            8
#define DESC_STATE_MASK             (0xFFu << DESC_STATE_SHIFT)
#define DESC_STATE_IDLE             0x00u
#define DESC_STATE_OK               0x01u
#define DESC_STATE_CRC_ERR          0x02u
#define DESC_STATE_RD_ERR           0x03u
#define DESC_STATE_WR_ERR           0x04u
#define DESC_STATE_IN_PROGRESS      0xFFu

// Macros to encode / decode in_size / out_size words
#define DESC_IN_SIZE(data, pad)     (((uint32_t)(data) & 0x00FFFFFFu) | \
                                     ((uint32_t)(pad)  << 24))
#define DESC_OUT_SIZE(data, pad)    (((uint32_t)(data) & 0x00FFFFFFu) | \
                                     ((uint32_t)(pad)  << 24))
#define DESC_IN_DATA_BYTES(w)       ((w) & 0x00FFFFFFu)
#define DESC_IN_PAD_BYTES(w)        (((w) >> 24) & 0xFFu)
#define DESC_OUT_DATA_BYTES(w)      ((w) & 0x00FFFFFFu)
#define DESC_OUT_PAD_BYTES(w)       (((w) >> 24) & 0xFFu)

// Extract state byte from header_word
#define DESC_GET_STATE(hw)          (uint8_t)(((hw) >> DESC_STATE_SHIFT) & 0xFFu)

// Build header_word for host (control byte only; state byte = 0)
#define DESC_MAKE_HDR(valid, intr, last) \
    ((uint32_t)((valid) ? DESC_CTRL_VALID     : 0u) | \
     (uint32_t)((intr)  ? DESC_CTRL_INTERRUPT : 0u) | \
     (uint32_t)((last)  ? DESC_CTRL_LAST      : 0u))

// ---------------------------------------------------------------------------
// Driver context
// ---------------------------------------------------------------------------
// The caller allocates this struct and initialises all fields before calling
// aes_ip_init().  reg_read and reg_write must be provided by the platform.

typedef struct {
    uint32_t        base_addr;      // IP register base (physical / virtual)
    aes_ip_desc_t  *ring;           // Pointer to descriptor ring (CPU view)
    uint32_t        ring_phys;      // Physical address of ring (IP's view)
    uint32_t        ring_size;      // Number of descriptor slots (1-1024)
    uint32_t        tail;           // Software-managed tail index

    // Platform register I/O callbacks
    void     (*reg_write)(uint32_t base, uint32_t offset, uint32_t val);
    uint32_t (*reg_read) (uint32_t base, uint32_t offset);
} aes_ip_ctx_t;

// ---------------------------------------------------------------------------
// Driver API
// ---------------------------------------------------------------------------

// Initialise the IP: configure ring buffer address and size, set outstanding
// transaction limits, and verify the engine is in STOP state.
// Returns 0 on success, -1 if the engine is not in STOP state.
int aes_ip_init(aes_ip_ctx_t *ctx, uint32_t max_rd_out, uint32_t max_wr_out);

// Write the 128-bit AES key (little-endian word order: key[31:0] -> KEY_0).
// key[0..15] follows little-endian convention: key[0] is the LSB of KEY_0.
void aes_ip_write_key(aes_ip_ctx_t *ctx, const uint8_t key[16]);

// Select CRC algorithm (AES_IP_CRC_ALG_IEEE8023 or AES_IP_CRC_ALG_CASTAGNOLI).
void aes_ip_set_crc_alg(aes_ip_ctx_t *ctx, uint32_t alg);

// Append one descriptor to the ring and advance the tail pointer.
// The descriptor must already be written to ctx->ring[ctx->tail] by the
// caller before invoking this function.
// Returns 0 on success, -1 if the ring is full.
int aes_ip_submit(aes_ip_ctx_t *ctx);

// Write CTRL.START (transition STOP -> ACTIVE).
void aes_ip_start(aes_ip_ctx_t *ctx);

// Write CTRL.RESUME (transition PAUSE -> ACTIVE, or start from STOP).
void aes_ip_resume(aes_ip_ctx_t *ctx);

// Write CTRL.IMMEDIATE_STOP.
void aes_ip_stop(aes_ip_ctx_t *ctx);

// Return the current STATUS.STATE field.
uint32_t aes_ip_get_state(aes_ip_ctx_t *ctx);

// Poll until STATUS.STATE == expected_state or timeout_polls expires.
// Returns 0 when state is reached, -1 on timeout.
int aes_ip_wait_state(aes_ip_ctx_t *ctx, uint32_t expected_state,
                      uint32_t timeout_polls);

// Read and return the current IRQ_STATUS register value.
uint32_t aes_ip_irq_status(aes_ip_ctx_t *ctx);

// Clear specified IRQ_STATUS bits (write-1-to-clear).
void aes_ip_irq_clear(aes_ip_ctx_t *ctx, uint32_t mask);

// Enable/disable interrupt sources (IRQ_ENABLE register).
void aes_ip_irq_enable(aes_ip_ctx_t *ctx, uint32_t mask);

// Read CMD_HEAD_PTR (updated by IP after each descriptor is consumed).
uint32_t aes_ip_head_ptr(aes_ip_ctx_t *ctx);

#endif // AES_DECRYPT_IP_H
