// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DMA integration test for custom ReckOn memory path:
// 1) fill 256 KiB in DDR4,
// 2) copy DDR4 -> BRAM via iDMA,
// 3) verify BRAM content.


#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "util.h"
#include "printf.h"
#include <stdint.h>
//#include <stdlib.h>
//#include <stdio.h>


#define DDR4_TO_BRAM_BYTES   (256u * 1024u)
#define WORD_BYTES           4u
#define TOTAL_WORDS          (DDR4_TO_BRAM_BYTES / WORD_BYTES)
#define BRAM_BASE_ADDR       0x48000000ull
#define BRAM_READBACK_ENABLE 1

#define STEP_START   0xB0010001u
#define STEP_WRITES  0xB0010002u
#define STEP_READS   0xB0010003u

int main(void) {
    volatile uint32_t *bram = (volatile uint32_t *)BRAM_BASE_ADDR;
    volatile uint32_t *scratch3 = reg32(&__base_regs, CHESHIRE_SCRATCH_3_REG_OFFSET);
    volatile uint32_t *scratch2 = reg32(&__base_regs, CHESHIRE_SCRATCH_2_REG_OFFSET);
    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, __BOOT_BAUDRATE);


    __asm__ volatile("li t0,0xdeb0");

    *scratch3 = STEP_START;

    // Step 1: write first and last word directly in the 256 KiB BRAM window.
    uint32_t first_word = 0xDEADBEEFu;
    uint32_t last_idx = TOTAL_WORDS - 1;
    uint32_t last_word = 0xFEEDC0DEu;; 
    bram[0] = first_word;
    __asm__ volatile("li t0,0xdeb1");
    bram[last_idx] = last_word;
    __asm__ volatile("li t0,0xdeb2");

    
    //printf("dio porco \n");
    //uart_write_flush(&__base_uart);

    fence();
    //*scratch3 = STEP_WRITES;
    //*scratch2= 0x1u;

#if BRAM_READBACK_ENABLE

    // Read back from the same BRAM addresses.
    uint32_t got_first = bram[0];
    uint32_t got_last = bram[last_idx];

    printf("First word: 0x%08X,  @index 0: 0x%08X\n", first_word, got_first);
    printf("Last word: 0x%08X,  @index %u: 0x%08X\n", last_word, last_idx, got_last);
    uart_write_flush(&__base_uart);

    //uart_write_flush(&__base_uart);
    int errors = 0;
    if (got_first != first_word) ++errors;
    if (got_last != last_word) ++errors;

    *scratch3 = STEP_READS;

    // Return code is consumed by testbench; avoids UART polling bottlenecks in sim.
    return errors;
#else
    // Default write-only mode avoids potential BRAM read-path deadlock in simulation.
    return 0;
#endif
}
