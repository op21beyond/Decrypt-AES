# =============================================================================
# File        : Makefile
# Project     : AES Decryption Engine IP
# Company     : SSVD
# Description : Build rules for host software tests.
#
#   sw_test  — pure software reference; runs on any host (Linux/macOS/WSL)
#   ip_test  — IP hardware driver test
#               Default: compiled with -DSIM_MMIO (no real hardware needed)
#               For target: omit SIM_MMIO and adapt MMIO in ip_test.c
# =============================================================================

CC      := gcc
CFLAGS  := -O2 -Wall -Wextra -std=c99

COMMON_SRC := aes128_ctr.c crc32.c

.PHONY: all clean

all: sw_test ip_test

sw_test: sw_test.c $(COMMON_SRC)
	$(CC) $(CFLAGS) -o $@ $^

ip_test: ip_test.c aes_decrypt_ip.c $(COMMON_SRC)
	$(CC) $(CFLAGS) -DSIM_MMIO -o $@ $^

clean:
	rm -f sw_test ip_test
