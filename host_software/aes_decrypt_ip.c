// =============================================================================
// File        : aes_decrypt_ip.c
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AES Decrypt IP driver implementation.
//               All register accesses are routed through ctx->reg_read /
//               ctx->reg_write so the driver is platform-agnostic.
// =============================================================================

#include "aes_decrypt_ip.h"

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------
static inline void wreg(const aes_ip_ctx_t *ctx, uint32_t offset, uint32_t val)
{
    ctx->reg_write(ctx->base_addr, offset, val);
}

static inline uint32_t rreg(const aes_ip_ctx_t *ctx, uint32_t offset)
{
    return ctx->reg_read(ctx->base_addr, offset);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

int aes_ip_init(aes_ip_ctx_t *ctx, uint32_t max_rd_out, uint32_t max_wr_out)
{
    // Engine must be in STOP before configuration is changed.
    uint32_t st = rreg(ctx, AES_IP_REG_STATUS) & AES_IP_STATUS_STATE_MASK;
    if (st != AES_IP_STATE_STOP)
        return -1;

    // Configure descriptor ring buffer.
    wreg(ctx, AES_IP_REG_CMD_BUF_ADDR, ctx->ring_phys);
    wreg(ctx, AES_IP_REG_CMD_BUF_SIZE, ctx->ring_size);
    wreg(ctx, AES_IP_REG_CMD_TAIL_PTR, 0u);
    ctx->tail = 0u;

    // Configure AXI outstanding transaction limits (clamp 1-16).
    uint32_t rd = (max_rd_out < 1u) ? 1u : (max_rd_out > 16u) ? 16u : max_rd_out;
    uint32_t wr = (max_wr_out < 1u) ? 1u : (max_wr_out > 16u) ? 16u : max_wr_out;
    wreg(ctx, AES_IP_REG_AXI_OUTSTAND,
         (rd << AES_IP_OUTSTAND_RD_SHIFT) | (wr << AES_IP_OUTSTAND_WR_SHIFT));

    return 0;
}

void aes_ip_write_key(aes_ip_ctx_t *ctx, const uint8_t key[16])
{
    // AES_KEY_0 holds key bits [31:0] (little-endian: key[0] is LSB).
    uint32_t w;
    w = (uint32_t)key[0]        | ((uint32_t)key[1]  << 8)
      | ((uint32_t)key[2] << 16) | ((uint32_t)key[3] << 24);
    wreg(ctx, AES_IP_REG_AES_KEY_0, w);

    w = (uint32_t)key[4]        | ((uint32_t)key[5]  << 8)
      | ((uint32_t)key[6] << 16) | ((uint32_t)key[7] << 24);
    wreg(ctx, AES_IP_REG_AES_KEY_1, w);

    w = (uint32_t)key[8]         | ((uint32_t)key[9]  << 8)
      | ((uint32_t)key[10] << 16) | ((uint32_t)key[11] << 24);
    wreg(ctx, AES_IP_REG_AES_KEY_2, w);

    w = (uint32_t)key[12]        | ((uint32_t)key[13] << 8)
      | ((uint32_t)key[14] << 16) | ((uint32_t)key[15] << 24);
    wreg(ctx, AES_IP_REG_AES_KEY_3, w);
}

void aes_ip_set_crc_alg(aes_ip_ctx_t *ctx, uint32_t alg)
{
    wreg(ctx, AES_IP_REG_CRC_CTRL, alg & 1u);
}

int aes_ip_submit(aes_ip_ctx_t *ctx)
{
    // Check ring not full: full when (tail+1) % size == head
    uint32_t next_tail = (ctx->tail + 1u) % ctx->ring_size;
    uint32_t head      = rreg(ctx, AES_IP_REG_CMD_HEAD_PTR) & 0x3FFu;
    if (next_tail == head)
        return -1;

    // The descriptor at ctx->ring[ctx->tail] must already be filled by caller.
    // Advance tail: write to IP register to inform it of the new descriptor.
    ctx->tail = next_tail;
    wreg(ctx, AES_IP_REG_CMD_TAIL_PTR, ctx->tail);
    return 0;
}

void aes_ip_start(aes_ip_ctx_t *ctx)
{
    wreg(ctx, AES_IP_REG_CTRL, AES_IP_CTRL_START);
}

void aes_ip_resume(aes_ip_ctx_t *ctx)
{
    wreg(ctx, AES_IP_REG_CTRL, AES_IP_CTRL_RESUME);
}

void aes_ip_stop(aes_ip_ctx_t *ctx)
{
    wreg(ctx, AES_IP_REG_CTRL, AES_IP_CTRL_IMMEDIATE_STOP);
}

uint32_t aes_ip_get_state(aes_ip_ctx_t *ctx)
{
    return rreg(ctx, AES_IP_REG_STATUS) & AES_IP_STATUS_STATE_MASK;
}

int aes_ip_wait_state(aes_ip_ctx_t *ctx, uint32_t expected_state,
                      uint32_t timeout_polls)
{
    for (uint32_t i = 0; i < timeout_polls; i++) {
        if (aes_ip_get_state(ctx) == expected_state)
            return 0;
    }
    return -1;
}

uint32_t aes_ip_irq_status(aes_ip_ctx_t *ctx)
{
    return rreg(ctx, AES_IP_REG_IRQ_STATUS);
}

void aes_ip_irq_clear(aes_ip_ctx_t *ctx, uint32_t mask)
{
    wreg(ctx, AES_IP_REG_IRQ_STATUS, mask);  // W1C
}

void aes_ip_irq_enable(aes_ip_ctx_t *ctx, uint32_t mask)
{
    wreg(ctx, AES_IP_REG_IRQ_ENABLE, mask);
}

uint32_t aes_ip_head_ptr(aes_ip_ctx_t *ctx)
{
    return rreg(ctx, AES_IP_REG_CMD_HEAD_PTR) & 0x3FFu;
}
