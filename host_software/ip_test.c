// =============================================================================
// File        : ip_test.c
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AES Decrypt IP hardware test.
//               Programs the IP via the driver (aes_decrypt_ip.c), submits
//               two descriptor-based jobs, and verifies plaintext output.
//
//               Target: bare-metal or RTOS environment on the SoC.
//               The MMIO layer at the bottom of this file must be adapted to
//               the platform (memory-mapped I/O address and bus access macros).
//
//               Build (host-side compilation check only; no real MMIO):
//                 gcc -O2 -Wall -DSIM_MMIO -o ip_test
//                     ip_test.c aes_decrypt_ip.c aes128_ctr.c crc32.c
//
//               When SIM_MMIO is defined, register reads return a simulated
//               STATUS=STOP value so the program compiles and links.  A
//               functional run requires the actual IP or an RTL simulation
//               with a VPI/DPI MMIO bridge.
// =============================================================================

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "aes_decrypt_ip.h"
#include "aes128_ctr.h"
#include "crc32.h"
#include "test_vectors.h"

// ---------------------------------------------------------------------------
// Platform MMIO layer
// ---------------------------------------------------------------------------
// Replace the bodies of mmio_write32 / mmio_read32 with the appropriate
// platform memory-access primitives (e.g., *((volatile uint32_t*)(addr)) ).

#ifdef SIM_MMIO
// Simulation stub: register file modelled as a small array.
// Enough to satisfy the driver without real hardware.
static uint32_t sim_regs[0x44 / 4 + 1];
static int      sim_started;

static void mmio_write32(uint32_t base, uint32_t offset, uint32_t val)
{
    (void)base;
    sim_regs[offset / 4] = val;
    if (offset == AES_IP_REG_CTRL) {
        if (val & (AES_IP_CTRL_START | AES_IP_CTRL_RESUME))
            sim_started = 1;
        if (val & AES_IP_CTRL_IMMEDIATE_STOP)
            sim_started = 0;
    }
}

static uint32_t mmio_read32(uint32_t base, uint32_t offset)
{
    (void)base;
    if (offset == AES_IP_REG_STATUS)
        // Always report STOP so wait_state returns immediately.
        return AES_IP_STATE_STOP;
    if (offset == AES_IP_REG_CMD_HEAD_PTR)
        return sim_regs[AES_IP_REG_CMD_TAIL_PTR / 4];  // head == tail (empty)
    return sim_regs[offset / 4];
}

#else // Real hardware MMIO — edit base address and access macros as needed.

#define IP_BASE_ADDR  0x40010000u   // EDIT: physical base address of the IP

static void mmio_write32(uint32_t base, uint32_t offset, uint32_t val)
{
    volatile uint32_t *reg = (volatile uint32_t *)(uintptr_t)(base + offset);
    *reg = val;
}

static uint32_t mmio_read32(uint32_t base, uint32_t offset)
{
    volatile uint32_t *reg = (volatile uint32_t *)(uintptr_t)(base + offset);
    return *reg;
}

#endif // SIM_MMIO

// ---------------------------------------------------------------------------
// Static memory allocations
// Align descriptor ring to 32-byte boundary (each descriptor = 32 bytes).
// ---------------------------------------------------------------------------
#define RING_SIZE   4u          // number of descriptor slots

// Maximum input buffer: 16 (header) + 64 (ciphertext) + 4 (CRC) = 84 bytes;
// pad to next 8-byte boundary -> 88 bytes.
#define MAX_INBUF   88u
#define MAX_OUTBUF  64u

// In a real system these would be in a DMA-accessible memory region.
static aes_ip_desc_t g_ring[RING_SIZE]              __attribute__((aligned(32)));
static uint8_t       g_inbuf[TV_TC_COUNT][MAX_INBUF] __attribute__((aligned(8)));
static uint8_t       g_outbuf[TV_TC_COUNT][MAX_OUTBUF];

// Physical address of g_ring (identity-mapped in bare-metal; update for MMU).
#ifdef SIM_MMIO
#define RING_PHYS_ADDR  ((uint32_t)(uintptr_t)g_ring)
#else
#define RING_PHYS_ADDR  ((uint32_t)(uintptr_t)g_ring)  // EDIT if MMU is used
#endif

// ---------------------------------------------------------------------------
// Utility
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
// Build all input buffers and write descriptors to the ring.
// Returns the index of the last descriptor written.
// ---------------------------------------------------------------------------
static void build_test_data(void)
{
    for (uint32_t i = 0; i < TV_TC_COUNT; i++) {
        const tv_tc_t *tc = &TV_TC[i];

        // Build complete input buffer: AES header + ciphertext + CRC
        tv_build_inbuf(i, g_inbuf[i]);

        // Fill descriptor fields (header_word set valid last, after memory is ready)
        g_ring[i].in_addr  = (uint32_t)(uintptr_t)g_inbuf[i];
        g_ring[i].out_addr = (uint32_t)(uintptr_t)g_outbuf[i];
        g_ring[i].in_size  = DESC_IN_SIZE(tc->data_bytes, tc->pad_bytes);
        g_ring[i].out_size = DESC_OUT_SIZE(tc->data_bytes, 0u);
        g_ring[i].reserved[0] = 0u;
        g_ring[i].reserved[1] = 0u;
        g_ring[i].reserved[2] = 0u;

        // Set valid bit last (memory barrier may be needed on cached systems)
        g_ring[i].header_word = DESC_MAKE_HDR(1, tc->interrupt, tc->last);
    }
}

// ---------------------------------------------------------------------------
// Wait until the IP finishes all submitted descriptors.
// Handles PAUSE state caused by TC1 (interrupt=1).
// Returns 0 on success, -1 on timeout or bus error.
// ---------------------------------------------------------------------------
#define POLL_TIMEOUT  1000000u

static int wait_all_done(aes_ip_ctx_t *ctx, uint32_t num_desc)
{
    uint32_t prev_head = 0u;
    (void)num_desc;

    // Loop until engine reaches STOP (after the last descriptor with last=1).
    for (uint32_t polls = 0; polls < POLL_TIMEOUT; polls++) {
        uint32_t state = aes_ip_get_state(ctx);

        // Check for bus error
        uint32_t status = ctx->reg_read(ctx->base_addr, AES_IP_REG_STATUS);
        if (status & AES_IP_STATUS_BUS_ERROR) {
            printf("  ERROR: AXI bus error detected (STATUS=0x%08X)\n", status);
            return -1;
        }

        if (state == AES_IP_STATE_PAUSE) {
            // Descriptor with interrupt=1 completed; clear IRQ and resume.
            uint32_t irq = aes_ip_irq_status(ctx);
            printf("  PAUSE reached, IRQ_STATUS=0x%08X — clearing and resuming\n", irq);
            aes_ip_irq_clear(ctx, irq);
            aes_ip_resume(ctx);
            continue;
        }

        if (state == AES_IP_STATE_STOP) {
            uint32_t head = aes_ip_head_ptr(ctx);
            (void)prev_head;
            (void)head;
            return 0;
        }
    }

    printf("  ERROR: timeout waiting for STOP state\n");
    return -1;
}

// ---------------------------------------------------------------------------
// Verify output buffers against expected plaintext
// ---------------------------------------------------------------------------
static int verify_results(void)
{
    int fail = 0;
    for (uint32_t i = 0; i < TV_TC_COUNT; i++) {
        const tv_tc_t *tc = &TV_TC[i];

        // Check IP-written descriptor state byte
        uint8_t dstate = DESC_GET_STATE(g_ring[i].header_word);
        int desc_ok = (dstate == DESC_STATE_OK);

        // Check decrypted output
        int data_ok = bytes_eq(g_outbuf[i], TV_PLAINTEXT, tc->data_bytes);

        printf("  [%s] desc_state=0x%02X %s  data=%s\n",
               tc->name,
               dstate,
               desc_ok ? "(OK)" : "(ERR)",
               data_ok ? "MATCH" : "MISMATCH");

        if (data_ok)
            print_hex("decrypted", g_outbuf[i], tc->data_bytes);

        if (!desc_ok || !data_ok)
            fail++;
    }
    return fail;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void)
{
    printf("=============================================================\n");
    printf("  AES Decrypt IP — Hardware Driver Test\n");
#ifdef SIM_MMIO
    printf("  *** Running with simulation MMIO stub ***\n");
    printf("  *** Functional verification requires real IP or RTL sim ***\n");
#endif
    printf("=============================================================\n\n");

    // Build input buffers and descriptor ring contents.
    memset(g_outbuf, 0, sizeof(g_outbuf));
    build_test_data();

    // Initialise driver context.
    aes_ip_ctx_t ctx = {
#ifdef SIM_MMIO
        .base_addr  = 0u,
#else
        .base_addr  = IP_BASE_ADDR,
#endif
        .ring       = g_ring,
        .ring_phys  = RING_PHYS_ADDR,
        .ring_size  = RING_SIZE,
        .tail       = 0u,
        .reg_write  = mmio_write32,
        .reg_read   = mmio_read32
    };

    // Step 1: Initialise IP
    printf("[STEP 1] Initialise IP (ring @ 0x%08X, %u slots)\n",
           RING_PHYS_ADDR, RING_SIZE);
    if (aes_ip_init(&ctx, 16u, 16u) != 0) {
        printf("  ERROR: IP not in STOP state at init\n");
        return EXIT_FAILURE;
    }

    // Step 2: Write AES key
    printf("[STEP 2] Write AES-128 key\n");
    aes_ip_write_key(&ctx, TV_KEY);

    // Step 3: Submit descriptors (both test cases in sequence)
    printf("[STEP 3] Submit %u descriptors\n", TV_TC_COUNT);
    for (uint32_t i = 0; i < TV_TC_COUNT; i++) {
        // aes_ip_submit advances ctx.tail and writes CMD_TAIL_PTR.
        // The descriptor at g_ring[i] was already populated by build_test_data().
        // We must set ctx.tail to i before calling submit so it points at
        // the correct slot.
        ctx.tail = i;

        // Select CRC algorithm for this job (can change between descriptors).
        aes_ip_set_crc_alg(&ctx, TV_TC[i].crc_alg);

        if (aes_ip_submit(&ctx) != 0) {
            printf("  ERROR: ring full at index %u\n", i);
            return EXIT_FAILURE;
        }
        printf("  Submitted [%s]: in_addr=0x%08X  out_addr=0x%08X\n",
               TV_TC[i].name,
               g_ring[i].in_addr,
               g_ring[i].out_addr);
    }

    // Step 4: Start IP
    printf("[STEP 4] Start IP\n");
    aes_ip_irq_enable(&ctx, AES_IP_IRQ_DESCRIPTOR_DONE | AES_IP_IRQ_BUS_ERROR);
    aes_ip_start(&ctx);

    // Step 5: Wait for all jobs to complete
    printf("[STEP 5] Waiting for completion...\n");
    int rc = wait_all_done(&ctx, TV_TC_COUNT);
    if (rc != 0) {
        printf("  ERROR: did not complete cleanly\n");
        return EXIT_FAILURE;
    }
    printf("  Engine returned to STOP\n\n");

    // Step 6: Verify output
    printf("[STEP 6] Verify results\n");
    int fail = verify_results();

    printf("\n=============================================================\n");
    if (fail == 0)
        printf("  All %u jobs PASSED\n", TV_TC_COUNT);
    else
        printf("  %d job(s) FAILED\n", fail);
    printf("=============================================================\n");

    return (fail == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
