// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ================================================================
// FPGA-Neural v4 (generic neural accelerator) -- ESP32 host API.
// ONE link to the FPGA: the Quad-SPI port (hardware/v4/rtl/
// qspi_data_port.v) carries DDR3 transfers, registers, status and the
// configuration-flash access. Optional GPIOs: sys_rst (MIG reset) and
// data_ready_n (end-of-run interrupt).
//
// DDR3 layout (addresses in 128-bit words, see hardware/v4/rtl/
// v4_boot.v and hardware/v4/model/v4_compile.py):
//   hdr_w     boot header (2 words: pass count, table/image/param/result
//             addresses, image and output sizes, magic)
//   desc      descriptor table (3 words per pass)
//   img_w     input, img_bytes bytes (img_words x 16, from the header), in
//             the layout the compiler gives it: INT8 HWC; a network whose
//             first layer is Conv1 takes every image row zero-padded to a
//             multiple of 16 bytes (fpga_v4_pad_rows; no padding when
//             w*c is a multiple of 16, e.g. 112x112x3), any other first
//             layer takes every pixel's channels zero-padded to its
//             16-channel groups (fpga_v4_pad_pixels). The blob holds an
//             example image there.
//   param     parameter image
//   result_w  output: out_len bytes (out_words x 16) of INT8 values in the
//             hardware layout (channels padded to 16-channel groups, per
//             position), then 1 statistics word
// Everything except the image is written ONCE (fpga_v4_load_blob with
// the image generated offline); per inference only the image goes over
// the link (fpga_v4_infer).
//
// Byte order: a 128-bit word's byte k is bits [8k+7:8k], i.e. on the
// little-endian ESP32 a byte buffer IS the word array.
// ================================================================
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FPGA_V4_MAGIC        0x344E4E56u   // "VNN4"
// defaults of a layout written by hand with img_bytes / out_len = 0: the
// MobileFaceNet benchmark (gen_mfn test model, 112 x 112 x 3 in, 128 out)
#define FPGA_V4_MFN_IMAGE_BYTES  (112 * 112 * 3)
#define FPGA_V4_MFN_OUT_LEN      128

typedef struct {
    uint32_t hdr_w;       // boot header, 128-bit word address (NETWORK_BASE = 4 * hdr_w)
    uint32_t img_w;       // input image
    uint32_t result_w;    // output words + statistics word
    uint32_t img_bytes;   // input bytes (multiple of 16); 0 = FPGA_V4_MFN_IMAGE_BYTES
    uint32_t out_len;     // output bytes (multiple of 16); 0 = FPGA_V4_MFN_OUT_LEN
} fpga_v4_layout_t;

// Layout of a model image built by v4_compile.py / gen_mfn +
// ddr_hex_to_bin.py: reads the boot header at hdr_w inside the blob
// (image address and size, result address, output size) and checks its
// magic.
esp_err_t fpga_v4_layout_from_blob(const uint8_t *blob, size_t len, uint32_t hdr_w, fpga_v4_layout_t *lay);

typedef struct {
    uint32_t core_cycles;       // measured by the FPGA core itself
    uint32_t param_wait_cycles; // of which waiting for DDR3 parameters
    bool     error;             // core / boot error
} fpga_v4_stats_t;

// Input layout for a network whose first layer is Conv1: h rows of w*c
// INT8 (HWC) -> each row zero-padded to a multiple of 16 bytes. dst holds
// h * align16(w*c) bytes (= img_bytes).
void fpga_v4_pad_rows(const int8_t *src, int h, int w, int c, int8_t *dst);
// Input layout for a network whose first layer is not Conv1:
// h*w pixels of c INT8 channels (HWC) -> each pixel's channels followed by
// zeros up to cpad (the first layer's input channels padded to 16-channel
// groups, = img_bytes / (h*w)). dst holds h*w*cpad bytes.
void fpga_v4_pad_pixels(const int8_t *src, int h, int w, int c, int cpad, int8_t *dst);

// ---------------- the Quad-SPI link (qspi_data_port.v) ----------------
// ESP32-S3 SPI2 in QIO on its IO_MUX pins (80 MHz), half duplex,
// everything on 4 lines, high nibble first. Every command starts with a
// 56-bit header: cmd 8 bit, then {W[31:0], len[15:0]}.
//   0x1A WRITE       W = 128-bit DDR3 word, len = words, then the data
//   0x2A READ        W, len; 64 dummy clocks, then the data
//   0x3A REG_WRITE   W = value, len = register; no data
//   0x4A STATUS      64 dummy clocks, then one 16-byte status word
//   0x5A FLASH_XFER  len = bytes (1..512) for the configuration flash,
//                    one flash transaction; data = those bytes, padded
//                    to whole 16-byte words
//   0x6A FLASH_READ  len = words (1..32) of the flash responses; 64
//                    dummy clocks, then the words
// The ESP32-S3 SPI address register is 32 bits wide (esp_hal_gpspi
// spi_ll_set_address) and its half-duplex mode cannot have MOSI and MISO
// data in one transaction, so the driver sends the 7-byte header as QIO
// DATA (wire-identical to cmd + addr on 4 lines) and keeps CS low
// (SPI_TRANS_CS_KEEP_ACTIVE, bus acquired) for the payload transaction.
#define FPGA_V4_QSPI_CMD_WRITE      0x1A
#define FPGA_V4_QSPI_CMD_READ       0x2A
#define FPGA_V4_QSPI_CMD_REG_WRITE  0x3A
#define FPGA_V4_QSPI_CMD_STATUS     0x4A
#define FPGA_V4_QSPI_CMD_FLASH_XFER 0x5A
#define FPGA_V4_QSPI_CMD_FLASH_READ 0x6A
#define FPGA_V4_QSPI_DUMMY          64

#define FPGA_V4_REG_CONTROL         0x01   // bit1: start one inference
#define FPGA_V4_REG_NETWORK_BASE    0x04   // DDR3 32-bit-word address of the header (= 4 * hdr_w)
#define FPGA_V4_CONTROL_START       0x2u
#define FPGA_V4_DEVICE_ID           0x4E505604u   // "NPV" + 4: Quad-SPI-only v4 board
#define FPGA_V4_FLASH_XFER_MAX      512           // bytes per flash transaction

typedef struct fpga_v4_qspi_s *fpga_v4_qspi_handle_t;

typedef struct {
    spi_host_device_t spi_host;   // SPI2_HOST (IO_MUX pins for 80 MHz)
    int pin_sclk, pin_cs, pin_io0, pin_io1, pin_io2, pin_io3;
    int clock_speed_hz;           // 80 MHz target; validate on the real board
    int pin_sys_rst;              // -1 = not wired; active low (MIG reset), open level 1
    int pin_data_ready_n;         // -1 = not wired; low = run finished or error
} fpga_v4_qspi_config_t;

typedef struct {
    uint32_t id;                  // FPGA_V4_DEVICE_ID
    uint32_t network_base;        // last NETWORK_BASE written
    bool calibrated;              // DDR3 calibration complete
    bool error;                   // boot / core error
    bool busy;                    // a run is in progress
    bool done;                    // a run finished (cleared by the next start)
    bool flash_busy;              // a FLASH_XFER transaction is running
} fpga_v4_status_t;

esp_err_t fpga_v4_qspi_init(const fpga_v4_qspi_config_t *cfg, fpga_v4_qspi_handle_t *out);
esp_err_t fpga_v4_qspi_write(fpga_v4_qspi_handle_t q, uint32_t dst_w, const void *data, size_t len);
esp_err_t fpga_v4_qspi_read(fpga_v4_qspi_handle_t q, uint32_t src_w, void *out, size_t len);
esp_err_t fpga_v4_reg_write(fpga_v4_qspi_handle_t q, uint16_t reg, uint32_t value);
// Reading the status also releases data_ready_n.
esp_err_t fpga_v4_read_status(fpga_v4_qspi_handle_t q, fpga_v4_status_t *st);
// sys_rst low for hold_us, then released; ESP_ERR_NOT_SUPPORTED if not wired.
esp_err_t fpga_v4_board_reset(fpga_v4_qspi_handle_t q, uint32_t hold_us);
esp_err_t fpga_v4_wait_calib(fpga_v4_qspi_handle_t q, uint32_t timeout_ms);
// Waits for the end of the run started last (STATUS done or error).
esp_err_t fpga_v4_wait_run(fpga_v4_qspi_handle_t q, uint32_t timeout_ms);
// data_ready_n falling-edge interrupt; ESP_ERR_NOT_SUPPORTED if not wired.
esp_err_t fpga_v4_data_ready_isr_add(fpga_v4_qspi_handle_t q, gpio_isr_t cb, void *arg);
// One configuration-flash transaction: n bytes (1..FPGA_V4_FLASH_XFER_MAX)
// with CS low for all of them; rx (may be NULL) gets the n bytes the
// flash returned, byte k during host byte k.
esp_err_t fpga_v4_flash_xfer(fpga_v4_qspi_handle_t q, const uint8_t *tx, size_t n, uint8_t *rx);

// One-time model load: the whole image produced offline (header,
// descriptors, parameters) at its DDR3 base.
esp_err_t fpga_v4_load_blob(fpga_v4_qspi_handle_t q, uint32_t dst_w, const uint8_t *blob, size_t len);

// One inference: image (lay->img_bytes) -> output (lay->out_len bytes,
// + on-chip statistics).
esp_err_t fpga_v4_infer(fpga_v4_qspi_handle_t q, const fpga_v4_layout_t *lay,
                        const int8_t *image,
                        int8_t *out, fpga_v4_stats_t *stats,
                        uint32_t timeout_ms);

// Pipelined use (two layouts A/B, i.e. two headers each with its own
// image and result areas): write the NEXT image while the current one
// computes, then start it as soon as the current one is done.
esp_err_t fpga_v4_stage_image(fpga_v4_qspi_handle_t q, const fpga_v4_layout_t *lay,
                              const int8_t *image);
esp_err_t fpga_v4_start(fpga_v4_qspi_handle_t q, const fpga_v4_layout_t *lay);
esp_err_t fpga_v4_finish(fpga_v4_qspi_handle_t q, const fpga_v4_layout_t *lay,
                         int8_t *out, fpga_v4_stats_t *stats, uint32_t timeout_ms);

// ---------------- board bring-up / self test (fpga_neural_v4_bringup.c) ----------------
// One call runs the first-power-on checklist of the datasheet (§14.11):
// reset, DDR3 calibration, DEVICE_ID, DDR3 write/read over Quad-SPI
// (two patterns, two lengths), model load, one inference and the
// comparison with the expected output. Every step is logged; the first
// failing step stops the test and is reported.
typedef enum {
    FPGA_V4_STEP_RESET = 1, FPGA_V4_STEP_CALIB, FPGA_V4_STEP_DEVICE_ID,
    FPGA_V4_STEP_QSPI_MEM, FPGA_V4_STEP_LOAD,
    FPGA_V4_STEP_INFER, FPGA_V4_STEP_COMPARE, FPGA_V4_STEP_DONE,
} fpga_v4_step_t;

typedef struct {
    const uint8_t *blob;          // model image for DDR3 word 0 (ddr_hex_to_bin.py); NULL = already loaded
    size_t blob_len;              // multiple of 16
    const int8_t *image;          // input image; NULL = the one in the blob at lay.img_w
    const int8_t *golden;         // expected output (lay.out_len bytes); NULL = no comparison
    int8_t *out;                  // output buffer, lay.out_len bytes
    fpga_v4_layout_t lay;         // fpga_v4_layout_from_blob()
    uint32_t scratch_w;           // free DDR3 words for the bus tests (8 words used)
    uint32_t rst_hold_us;         // 0 = no sys_rst pulse
    uint32_t calib_timeout_ms;
    uint32_t infer_timeout_ms;
} fpga_v4_bringup_cfg_t;

typedef struct {
    fpga_v4_step_t failed_step;   // FPGA_V4_STEP_DONE when everything passed
    uint32_t device_id;
    int mismatches;               // output values different from golden
    fpga_v4_stats_t stats;
} fpga_v4_bringup_report_t;

esp_err_t fpga_v4_bringup(fpga_v4_qspi_handle_t q,
                          const fpga_v4_bringup_cfg_t *cfg, fpga_v4_bringup_report_t *rep);

// ---------------- FPGA configuration from the ESP32 (fpga_neural_v4_config.c) ----------------
// The module brings JTAG (TCK/TMS/TDI/TDO), PROGRAM_B, INIT_B and DONE to
// the 40-pin board-to-board connector (datasheet §9.8); on the base they go
// to ESP32 GPIOs.
// The FPGA boots by itself from the W25Q32JV (Master SPI x1, pins
// FCS_B/D00/D01/CCLK). The ESP32 is needed only to (re)write that flash:
//
//   flash blank (first power-on) or bad (recovery):
//     fpga_v4_jtag_load_sram()  -- bitstream into the FPGA's SRAM over JTAG
//     fpga_v4_flash_program()   -- same bitstream into the flash, through
//                                  the running design (Quad-SPI FLASH_XFER), then
//                                  PROGRAM_B pulse and DONE check
//   field update: only fpga_v4_flash_program().
//
// Bitstream: the Vivado .bit file (header parsed, payload used as is) in
// a data partition of the ESP32 (fpga_v4_bitstream_from_partition), or any
// buffer. The flash holds the bare payload from address 0 (= the .bin of
// write_cfgmem -interface SPIx1, no bit swap in SPI mode). Over JTAG the
// payload goes through CFG_IN MSB first per byte (UG470 ch. 6).

typedef struct {
    int pin_tck, pin_tms, pin_tdi, pin_tdo;   // -1: JTAG not wired (only flash updates possible)
    int pin_program_b;                        // driven open-drain (pull-up on the module)
    int pin_init_b;                           // input, -1 = not wired
    int pin_done;                             // input
} fpga_v4_cfg_pins_t;

#define FPGA_V4_IDCODE        0x03631093u     // XC7A100T, version nibble [31:28] masked
#define FPGA_V4_FLASH_JEDEC   0xEF4016u       // W25Q32JV-IQ/JQ (manufacturer EF, type 40, capacity 16)
#define FPGA_V4_FLASH_SIZE    (4u * 1024 * 1024)

// GPIO setup: TCK/TMS/TDI outputs (low), TDO/INIT_B/DONE inputs, PROGRAM_B released.
esp_err_t fpga_v4_cfg_pins_init(const fpga_v4_cfg_pins_t *p);
// DONE high within timeout_ms.
esp_err_t fpga_v4_wait_done(const fpga_v4_cfg_pins_t *p, uint32_t timeout_ms);
// PROGRAM_B low for 10 us, released, then waits INIT_B high and DONE high:
// the FPGA reloads itself from the flash. The Quad-SPI port and the DDR3
// restart: fpga_v4_wait_calib() before using them.
esp_err_t fpga_v4_reconfigure(const fpga_v4_cfg_pins_t *p, uint32_t timeout_ms);

// Bitstream payload of a Vivado .bit image (fields a..d skipped, field e);
// a buffer that already starts with the 0xFF padding is returned as is.
esp_err_t fpga_v4_bitstream_payload(const uint8_t *img, size_t len, const uint8_t **data, size_t *data_len);
// Maps the data partition `label` (e.g. "fpga") and returns the payload of
// the .bit written there (esptool / parttool). The mapping is kept.
esp_err_t fpga_v4_bitstream_from_partition(const char *label, const uint8_t **data, size_t *data_len);

// JTAG: IDCODE register (IR 0x09).
esp_err_t fpga_v4_jtag_idcode(const fpga_v4_cfg_pins_t *p, uint32_t *idcode);
// JTAG configuration of the SRAM (UG470 "JTAG configuration flow"): TLR,
// IDCODE check, JPROGRAM, wait INIT complete (INIT_B pin and IR capture
// bit 4), CFG_IN + payload, JSTART, 2000 TCK in Run-Test/Idle, TLR, DONE
// (IR capture bit 5 and the DONE pin). `bit` = .bit image or bare payload.
esp_err_t fpga_v4_jtag_load_sram(const fpga_v4_cfg_pins_t *p, const uint8_t *bit, size_t len, uint32_t timeout_ms);

// On-chip sensors through JTAG (XADC_DRP instruction, UG480 "DRP JTAG
// Interface"): no RTL involved, works while the design runs (the XADC DRP
// arbiter serializes JTAG and fabric transactions; the MIG's temperature
// monitor uses the fabric port). Needs the JTAG pins and the default
// BITSTREAM.GENERAL.JTAG_XADC = Enable.
typedef struct {
    float temp_c;      // die temperature, register 00h: code * 503.975 / 4096 - 273.15
    float vccint_v;    // 01h: code / 4096 * 3 V
    float vccaux_v;    // 02h
    float vccbram_v;   // 06h
} fpga_v4_sensors_t;
esp_err_t fpga_v4_read_sensors(const fpga_v4_cfg_pins_t *p, fpga_v4_sensors_t *out);
esp_err_t fpga_v4_read_temp_c(const fpga_v4_cfg_pins_t *p, float *temp_c);

// Config flash through the running design (Quad-SPI FLASH_XFER, flash
// clock ~19 MHz inside the FPGA, up to 512 bytes per transaction).
esp_err_t fpga_v4_flash_jedec_id(fpga_v4_qspi_handle_t q, uint32_t *id);
esp_err_t fpga_v4_flash_read(fpga_v4_qspi_handle_t q, uint32_t addr, uint8_t *out, size_t len);
// Erases [addr, addr + len) rounded out to 4 KB sectors; 64 KB blocks
// (D8h) where aligned, 4 KB sectors (20h) elsewhere.
esp_err_t fpga_v4_flash_erase(fpga_v4_qspi_handle_t q, uint32_t addr, size_t len);
// JEDEC check, erase, page program (256 B pages, all-0xFF pages skipped),
// read-back verify. addr must be 4 KB aligned. If `p` is not NULL, then
// fpga_v4_reconfigure(p, reboot_timeout_ms): the FPGA boots the new image.
esp_err_t fpga_v4_flash_program(fpga_v4_qspi_handle_t q, const fpga_v4_cfg_pins_t *p,
                                uint32_t addr, const uint8_t *data, size_t len,
                                uint32_t reboot_timeout_ms);

#ifdef __cplusplus
}
#endif
