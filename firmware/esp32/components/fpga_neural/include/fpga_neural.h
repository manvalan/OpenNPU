// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ================================================================
// FPGA-Neural -- ESP32 (ESP-IDF) host driver for the management SPI
// bus described in docs/FIRMWARE_SPEC.md. Real, from-spec
// implementation -- every opcode shape, register address/bit, and
// byte-order convention below is taken directly from that document
// (itself derived from the committed RTL's own header comments), not
// guessed.
//
// Scope (deliberately limited, per project decision): this is ONLY
// the SPI transport/opcode driver -- it does not build network
// descriptors, does not manage DDR3 memory layout, does not implement
// FreeRTOS task structure or a higher-level inference scheduler. Two
// real, mutually exclusive fabrication targets exist on this project
// (see docs/FIRMWARE_SPEC.md's own top-level note) and this driver
// supports BOTH, selected at init time via `fpga_neural_variant_t` --
// they are NOT protocol-compatible with each other, matching what
// silicon is actually flashed to the board.
//
// REAL, DISCLOSED, NOT-YET-CLOSED GAP (inherited from docs/
// FIRMWARE_SPEC.md SS8): the chained variant's own network-descriptor
// byte layout has never been verified via a real WRITE_MEM transaction
// end to end. This driver's own `write_mem`/`read_mem` primitives are
// real and tested against the documented protocol shape, but nothing
// downstream (descriptor serialization) has been built or verified
// yet -- that remains real, separate, future work.
//
// SPI electrical convention (derived directly from spi_host_bridge_
// v3.v's own sampling/shift-edge RTL, not assumed): MODE 0 (CPOL=0,
// CPHA=0) -- FPGA samples MOSI on sclk's rising edge, shifts MISO out
// on sclk's falling edge. MSB-first, CS active-low, one opcode byte
// starts every real transaction.
// ================================================================
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

// ---- real opcode bytes (docs/FIRMWARE_SPEC.md SS3, SS9.1-9.2) ----
// Shared by both variants: NOP, RESET, WRITE_MEM, READ_MEM, REG_WRITE,
// REG_READ, FLASH_XFER. WRITE_JOB/STATUS(0x20) are real, valid opcodes
// ONLY on the non-chained bridge -- inert (treated as unrecognized) on
// the chained one.
#define FPGA_NEURAL_OP_NOP         0x00
#define FPGA_NEURAL_OP_RESET       0x0F
#define FPGA_NEURAL_OP_WRITE_JOB   0x10 // non-chained only
#define FPGA_NEURAL_OP_STATUS      0x20 // non-chained only
#define FPGA_NEURAL_OP_WRITE_MEM   0x01
#define FPGA_NEURAL_OP_READ_MEM    0x02
#define FPGA_NEURAL_OP_REG_WRITE   0x30
#define FPGA_NEURAL_OP_REG_READ    0x31
#define FPGA_NEURAL_OP_FLASH_XFER  0x40

// ---- real register map (docs/FIRMWARE_SPEC.md SS3.3 / SS9.3) ----
// Addresses 0x00-0x03 are byte-for-byte identical in meaning across
// both variants; 0x04 (NETWORK_BASE) exists only on the chained one.
#define FPGA_NEURAL_REG_DEVICE_ID    0x00
#define FPGA_NEURAL_REG_CONTROL     0x01
#define FPGA_NEURAL_REG_STATUS      0x02
#define FPGA_NEURAL_REG_N_SLOTS     0x03
#define FPGA_NEURAL_REG_NETWORK_BASE 0x04 // chained only

// real, expected DEVICE_ID values (docs SS2.1 step3): "NPV" + protocol
// version -- 1 = spi_host_bridge_v3.v (non-chained), 2 =
// spi_host_bridge_v3_chained.v (v3 chained and the v4 board).
// fpga_neural_check_device_id() compares against the one matching the
// handle's variant.
#define FPGA_NEURAL_DEVICE_ID_EXPECTED         0x4E505601u
#define FPGA_NEURAL_DEVICE_ID_EXPECTED_CHAINED 0x4E505602u

// ---- CONTROL register bits (docs SS3.3 / SS9.3) ----
#define FPGA_NEURAL_CONTROL_SOFT_RST   (1u << 0) // both variants
#define FPGA_NEURAL_CONTROL_SEQ_START  (1u << 1) // chained only -- pulses network_sequencer.v's own `start`

// ---- non-chained STATUS bits (docs SS3.1 opcode 0x20 response AND
// REG_READ(0x02) -- bits 0-2 identical in both, bits 3-4 only visible
// via REG_READ since the 1-byte 0x20 opcode response is too narrow) ----
#define FPGA_NEURAL_NC_STATUS_JOB_BUSY           (1u << 0)
#define FPGA_NEURAL_NC_STATUS_MEM_BUSY           (1u << 1)
#define FPGA_NEURAL_NC_STATUS_LAST_JOB_ACCEPTED  (1u << 2)
#define FPGA_NEURAL_NC_STATUS_INIT_CALIB_COMPLETE (1u << 3) // REG_READ only
#define FPGA_NEURAL_NC_STATUS_DIR_ERROR           (1u << 4) // REG_READ only

// ---- chained STATUS bits (docs SS9.3 -- REDEFINED from the
// non-chained bit layout above; REG_READ(0x02) only, the 0x20 opcode
// does not exist on this bridge) ----
#define FPGA_NEURAL_CH_STATUS_MEM_BUSY            (1u << 0)
#define FPGA_NEURAL_CH_STATUS_INIT_CALIB_COMPLETE  (1u << 1)
#define FPGA_NEURAL_CH_STATUS_DIR_ERROR            (1u << 2)
#define FPGA_NEURAL_CH_STATUS_SEQ_BUSY             (1u << 3)
#define FPGA_NEURAL_CH_STATUS_SEQ_DONE             (1u << 4) // sticky, see docs SS9.3/SS9.5

// Which real fabrication target the flashed bitstream actually is --
// firmware must know this, the two protocols are not distinguishable
// on the wire (an opcode that's real on one is silently inert/NOP on
// the other, docs SS9.2).
typedef enum {
    FPGA_NEURAL_VARIANT_NONCHAINED = 0, // n16_system_ddr3_top.v / spi_host_bridge_v3.v
    FPGA_NEURAL_VARIANT_CHAINED    = 1, // n16_system_ddr3_chained_top.v / spi_host_bridge_v3_chained.v
} fpga_neural_variant_t;

// Real, non-chained WRITE_JOB payload (docs SS4.1) -- 26-bit byte
// addresses (x_base/w_base/result_addr), 16-bit node_id/n_tiles.
typedef struct {
    uint16_t node_id;
    uint32_t x_base;      // 26 bits significant
    uint32_t w_base;      // 26 bits significant
    uint16_t n_tiles;
    uint32_t result_addr; // 26 bits significant
} fpga_neural_job_t;

// Driver instance handle -- opaque to callers.
typedef struct fpga_neural_dev_s *fpga_neural_handle_t;

typedef struct {
    spi_host_device_t spi_host; // e.g. SPI2_HOST
    int pin_sclk;
    int pin_mosi;
    int pin_miso;
    int pin_cs;
    int pin_sys_rst;      // -1 if not wired on this board
    int pin_data_ready_n; // -1 if not wired on this board
    int clock_speed_hz;   // real management-SPI clock -- start conservative
                           // (e.g. 1-10MHz) and raise only after real,
                           // on-board signal-integrity validation; no
                           // real max has been characterized on
                           // hardware yet (docs' own open item, SS8)
    fpga_neural_variant_t variant;
} fpga_neural_config_t;

// ---- lifecycle ----

// Initializes the SPI bus + device and (if pin_sys_rst >= 0) the
// board-level reset GPIO. Does NOT touch pin_data_ready_n beyond
// configuring it as input -- callers that want interrupt-driven
// completion notification should call fpga_neural_data_ready_isr_add
// themselves (kept explicit/opt-in, not forced on every user).
esp_err_t fpga_neural_init(const fpga_neural_config_t *cfg, fpga_neural_handle_t *out_handle);
esp_err_t fpga_neural_deinit(fpga_neural_handle_t h);

// ---- SS2.1 real, recommended startup sequence helpers ----

// Pulses the board-level sys_rst pin (if wired) LOW for `hold_us`
// microseconds, then releases it high. sys_rst is ACTIVE LOW: it is the
// MIG's own reset (the real-MIG benches tb_v4_board_xsim.v and the v3
// MIG benches hold it at 0 and release it to 1), and on the board it
// has a 10 kOhm pull-up. After a reset the DDR3 recalibrates (wait for
// STATUS init_calib_complete) and its contents must be reloaded.
// No-op (returns ESP_ERR_NOT_SUPPORTED) if pin_sys_rst was -1 at init.
esp_err_t fpga_neural_board_reset(fpga_neural_handle_t h, uint32_t hold_us);

// Reads DEVICE_ID and compares against FPGA_NEURAL_DEVICE_ID_EXPECTED.
// Returns ESP_OK + *out_match=true only on an exact match -- per docs
// SS2.1 step3, a mismatch means don't trust anything else yet.
esp_err_t fpga_neural_check_device_id(fpga_neural_handle_t h, bool *out_match, uint32_t *out_raw);

// Polls REG_READ(STATUS) until the real init_calib_complete bit is
// set (bit3 non-chained / bit1 chained -- this function reads the
// right bit for whichever variant the handle was configured with).
// Returns ESP_ERR_TIMEOUT if `timeout_ms` elapses first. Real DDR3
// calibration timing has not been measured on hardware yet (docs SS8)
// -- pass a generous timeout.
esp_err_t fpga_neural_wait_calib_complete(fpga_neural_handle_t h, uint32_t timeout_ms);

// ---- SS3.2 generic register access (both variants, same wire shape) ----

esp_err_t fpga_neural_reg_write(fpga_neural_handle_t h, uint8_t reg_addr, uint32_t value);
esp_err_t fpga_neural_reg_read(fpga_neural_handle_t h, uint8_t reg_addr, uint32_t *out_value);

// ---- SS3 RESET (0x0F) -- same physical effect as CONTROL bit0 ----
esp_err_t fpga_neural_reset_pulse(fpga_neural_handle_t h);

// ---- non-chained-only: SS3.1 STATUS (0x20), SS4 WRITE_JOB ----

// Real, 1-byte STATUS opcode response (bits: see FPGA_NEURAL_NC_STATUS_*,
// only bits 0-2 are meaningful from this narrow opcode -- use
// fpga_neural_reg_read(STATUS) for bits 3-4). Returns ESP_ERR_INVALID_STATE
// if the handle's variant is not NONCHAINED.
esp_err_t fpga_neural_status_opcode(fpga_neural_handle_t h, uint8_t *out_status);

// Submits ONE real WRITE_JOB transaction (16-byte payload, docs
// SS4.1). Callers are responsible for the real SS4.2 octet-batching
// discipline (see fpga_neural_submit_batch below for a helper that
// enforces it) -- this raw primitive does not check w_base/n_tiles
// consistency itself.
esp_err_t fpga_neural_write_job(fpga_neural_handle_t h, const fpga_neural_job_t *job);

// Real, mandatory SS4.2 discipline helper: submits `count` jobs
// back-to-back with NO other transaction interleaved, after checking
// they all share the same w_base and n_tiles (returns
// ESP_ERR_INVALID_ARG before submitting anything if they don't --
// avoids the real, unrecoverable-without-reset director queue stall
// docs SS4.2 describes). `count` must equal N_SLOTS/2 (read N_SLOTS
// via fpga_neural_reg_read(REG_N_SLOTS) at startup, do not hardcode 8).
esp_err_t fpga_neural_submit_batch(fpga_neural_handle_t h, const fpga_neural_job_t *jobs, size_t count);

// Real SS5 result-readback helper: applies result_writeback.v's own
// addressing formula (mem_addr=result_addr*2 for value,
// result_addr*2+1 for node_id) and issues the two real READ_MEM
// transactions this requires.
esp_err_t fpga_neural_read_result(fpga_neural_handle_t h, uint32_t result_addr,
                                   int8_t *out_value, uint16_t *out_node_id);

// ---- chained-only: SS9.4 trigger sequence ----

// REG_WRITEs NETWORK_BASE. Must be called BEFORE
// fpga_neural_trigger_network_start, in a SEPARATE transaction (docs
// SS9.3's own explicit warning -- CONTROL bit1 uses whatever
// NETWORK_BASE already holds at the instant it's pulsed).
esp_err_t fpga_neural_set_network_base(fpga_neural_handle_t h, uint32_t network_base_word_addr);

// Pulses CONTROL bit1 -- starts the autonomous multi-layer run using
// whatever NETWORK_BASE currently holds.
esp_err_t fpga_neural_trigger_network_start(fpga_neural_handle_t h);

// Polls REG_READ(STATUS) bit4 (seq_done) until set. Real, important
// per docs SS9.5: reading STATUS here is what clears data_ready_n (if
// wired) -- this function's own successful return already does that
// acknowledgment, callers using the GPIO IRQ path don't need to do
// anything further for THAT purpose (though seq_done itself, in
// STATUS, only clears on the next start pulse -- see docs SS9.3/9.5,
// do not re-poll this function expecting it to go false again until
// the next real run starts).
esp_err_t fpga_neural_wait_seq_done(fpga_neural_handle_t h, uint32_t timeout_ms);

// ---- SS6.1 raw memory access (both variants, identical wire shape) ----
// Real, 16-bit-WORD address convention (host_mem_bridge.v's own,
// DIFFERENT from x_base/w_base/result_addr's 26-bit byte convention
// above -- do not mix the two, see docs SS6.1's own warning).

esp_err_t fpga_neural_write_mem(fpga_neural_handle_t h, uint32_t word_addr,
                                 const uint16_t *words, size_t count);
esp_err_t fpga_neural_read_mem(fpga_neural_handle_t h, uint32_t word_addr,
                                uint16_t *out_words, size_t count);

// ---- SS6.2 FLASH_XFER (both variants, identical) ----
// Raw passthrough: sends `tx_len` real command bytes, THEN 2 real
// trailing dummy bytes (docs' own measured EXP-0077 requirement --
// this function adds them automatically, callers must NOT include
// their own). `out_rx` must be at least `tx_len + 2` bytes; per docs,
// only bytes starting at index `tx_len` onward (i.e. the last real
// N+2 window) carry the real, stable, delayed flash response --
// interpreting them is a real SPI-NOR-command-specific concern left
// to the caller (see docs SS6.2's own opcode table).
esp_err_t fpga_neural_flash_xfer(fpga_neural_handle_t h, const uint8_t *tx, size_t tx_len,
                                  uint8_t *out_rx);

// Management SPI clock change (the SPI device is re-added with the new
// clock; same bus, pins and mode). `old_hz` (may be NULL) gets the
// previous clock. Used by the v4 config-flash code, which runs FLASH_XFER
// at 1.6 MHz (see fpga_neural_v4_config.c).
esp_err_t fpga_neural_set_clock(fpga_neural_handle_t h, int clock_speed_hz, int *old_hz);

// WARNING (found in the v4 config-flash co-simulation, 2026-10-06): the
// bridge takes every MISO bit from the latest flash response at each SCLK
// falling edge, so in a continuous stream the response to byte j is NOT
// a clean byte at any position when the next responses differ: at 10 MHz
// host byte j+2 carries bits 7..3 of response j and bits 2..0 of response
// j+1. Only repeated responses (status polling) come back intact. Multi-
// byte reads (JEDEC ID, Read Data) need the v4 config-flash code's 1.6 MHz
// rule: response j = {byte j+2 bit 7, byte j+1 bits 6..0}.
//
// Same passthrough WITHOUT the 2 trailing bytes: exactly opcode + `len`
// bytes, `out_rx` (may be NULL) gets the `len` bytes clocked back. The
// bridge relays EVERY host byte to the flash, so the 2 trailing bytes of
// fpga_neural_flash_xfer() reach the flash too: harmless for reads (more
// clocks), wrong for write-type commands -- the W25Q32JV executes Write
// Enable / Sector-Block Erase / Page Program only if /CS rises right
// after the command's last byte (datasheet rev G, 8.2.x), and 2 extra
// 0x00 bytes of a Page Program wrap into the page and clear its first
// bytes. Use this one for 06h/20h/D8h/02h; for reads, append the 2
// extra bytes yourself (the response to tx byte j comes back in
// out_rx[j + 2], see fpga_neural_v4_config.c).
// Keep the management SPI at <= 10 MHz for FLASH_XFER: the flash master
// needs 64 ui_clk cycles (~0.41 us) per byte and a host byte that arrives
// before it has finished is dropped by the bridge.
esp_err_t fpga_neural_flash_xfer_raw(fpga_neural_handle_t h, const uint8_t *tx, size_t len,
                                      uint8_t *out_rx);

// ---- SS5.1/SS9.5 data_ready_n GPIO helper (optional, opt-in) ----

// Configures pin_data_ready_n as a falling-edge interrupt source,
// invoking `cb` (from ISR context -- keep it minimal, e.g. a
// binary-semaphore give) each time it fires. No-op/ESP_ERR_NOT_SUPPORTED
// if pin_data_ready_n was -1 at init.
esp_err_t fpga_neural_data_ready_isr_add(fpga_neural_handle_t h, gpio_isr_t cb, void *arg);

#ifdef __cplusplus
}
#endif
