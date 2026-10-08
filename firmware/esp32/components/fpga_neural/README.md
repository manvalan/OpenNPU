# fpga_neural — ESP-IDF driver component

Real, from-spec ESP32 host driver for the management SPI bus described
in `docs/FIRMWARE_SPEC.md`. Implements the wire protocol only (opcode
framing, register map, WRITE_MEM/READ_MEM, WRITE_JOB, FLASH_XFER) —
it does not build network descriptors, manage the DDR3 memory layout,
or implement any inference scheduling. See `docs/FIRMWARE_SPEC.md` for
the authoritative protocol reference this component implements.

## v4 board (generic accelerator)

The v4 board has ONE host link: Quad-SPI (2026-10-07; the management SPI
is gone). Use only `fpga_neural_v4.h`: `fpga_v4_qspi_init()` (Quad-SPI
pins + `sys_rst` + `data_ready_n`), `fpga_v4_load_blob()`,
`fpga_v4_infer()`, `fpga_v4_read_status()`, `fpga_v4_reg_write()`,
`fpga_v4_bringup()` self test. DEVICE_ID (STATUS word bits [31:0]) is
`0x4E505604`. `fpga_neural.c` / `fpga_neural.h` are the v3 management-SPI
driver and are not used on v4. Reference: the v4 datasheet; ready-made
app: `firmware/esp32/v4_bringup`. Verified against the v4 RTL in the host
co-simulation `hardware/v4/sim/esp32_cosim/run_cosim.sh`; not yet run on
a real ESP32.

### v4 FPGA configuration from the ESP32

`fpga_neural_v4_config.c` / `fpga_neural_v4_partition.c` (API in
`fpga_neural_v4.h`): the FPGA boots by itself from its W25Q32JV; the
ESP32 waits DONE. Blank or bad flash: `fpga_v4_jtag_load_sram()` (GPIO
bit-bang JTAG, UG470 sequence), then `fpga_v4_flash_program()` (JEDEC
check, erase, page program, read-back verify, PROGRAM_B, DONE). Every
flash command is one `fpga_v4_flash_xfer()` = Quad-SPI FLASH_XFER: the
FPGA runs exactly those bytes (up to 512) as one flash transaction at
~19 MHz, then FLASH_READ returns the responses. Bitstream: Vivado `.bit`
in the `fpga` data partition. Tests:
`hardware/v4/sim/esp32_cosim/run_flash_cosim.sh` (JTAG + XADC against a
C TAP model; flash path against the RTL + a W25Q model).

Setup (details and error codes: datasheet §11.8):
1. wire TCK/TMS/TDI/TDO, PROGRAM_B (open drain), INIT_B, DONE from the
   40-pin board-to-board connector (datasheet §6.8) to ESP32 GPIOs (`fpga_v4_cfg_pins_t`; v4_bringup Kconfig
   `V4_TCK`..`V4_DONE`);
2. ESP32 flash >= 8 MB and a `fpga` data partition of 4 MB
   (`v4_bringup/partitions.csv`);
3. `parttool.py -p PORT write_partition --partition-name fpga --input v4_board_top_199.bit`;
4. `CONFIG_V4_FPGA_FLASH_MODE`: 0 never write, 1 only if the FPGA does
   not boot (default), 2 rewrite at every start;

Temperature: `fpga_v4_read_sensors()` / `fpga_v4_read_temp_c()` read the
XADC (die temperature, VCCINT, VCCAUX, VCCBRAM) over the same JTAG pins
with the XADC_DRP instruction (UG480), no FPGA logic involved; v4_bringup
monitors it (`CONFIG_V4_TEMP_MONITOR`, alarm `CONFIG_V4_TEMP_ALARM_C`).
Checked against the C TAP model only.

Example: `examples/v4_config_example.c` (first boot, update, one
inference; host syntax check with `gcc -c` against the co-simulation
stubs). Not yet built with ESP-IDF nor run on a real ESP32 / board.

## Two real, mutually exclusive targets

This project has two real, valid FPGA fabrication targets with
different (incompatible) SPI protocols. Pick the one matching the
actual bitstream flashed to your board at `fpga_neural_init()` time via
`fpga_neural_config_t.variant`:

- `FPGA_NEURAL_VARIANT_NONCHAINED` — `n16_system_ddr3_top.v` /
  `spi_host_bridge_v3.v`. Per-neuron `WRITE_JOB` submission (§3–§8 of
  the spec). **As of this writing, a real bug is under active
  investigation on this target** (wrong values on real hardware/xsim,
  see `hardware/v2/logs/experiments.log` EXP-0119) — do not build
  production firmware against it until that investigation closes.
- `FPGA_NEURAL_VARIANT_CHAINED` — `n16_system_ddr3_chained_top.v` /
  `spi_host_bridge_v3_chained.v`. Whole-network autonomous execution
  (§9 of the spec), real, end-to-end verified (67/67 PASS, EXP-0117).
  **Recommended.** One real, disclosed, open gap: the network
  descriptor's own byte layout has never been proven via a real
  `WRITE_MEM` transaction (see the spec's own §8) — this driver's
  `write_mem`/`read_mem` primitives are real and usable today, but
  descriptor *serialization* on top of them is separate, unbuilt work.

## Real hardware prerequisites this driver assumes

- SPI mode 0 (CPOL=0, CPHA=0), MSB-first, CS active-low — derived
  directly from `spi_host_bridge_v3.v`'s own sampling/shift-edge RTL,
  not assumed.
- `pin_sys_rst`/`pin_data_ready_n` are real, but their exact board
  location/polarity is still flagged tentative in
  `docs/PHYSICAL_REALIZATION.md` §7 — confirm against your actual board
  schematic before trusting this driver's defaults (active-low
  `sys_rst` idle state, active-low `data_ready_n`).
- No real management-SPI clock speed has been characterized on
  hardware yet (`docs/FIRMWARE_SPEC.md` §8's own disclosed gap) — start
  conservative (a few MHz) and raise only after real signal-integrity
  validation on your actual board.

## Minimal usage sketch (chained variant)

```c
#include "fpga_neural.h"

fpga_neural_config_t cfg = {
    .spi_host = SPI2_HOST,
    .pin_sclk = GPIO_NUM_18,
    .pin_mosi = GPIO_NUM_23,
    .pin_miso = GPIO_NUM_19,
    .pin_cs   = GPIO_NUM_5,
    .pin_sys_rst = -1,       // wire up and set the real GPIO once known
    .pin_data_ready_n = -1,  // ditto
    .clock_speed_hz = 1 * 1000 * 1000,
    .variant = FPGA_NEURAL_VARIANT_CHAINED,
};

fpga_neural_handle_t h;
ESP_ERROR_CHECK(fpga_neural_init(&cfg, &h));

bool id_ok; uint32_t raw_id;
ESP_ERROR_CHECK(fpga_neural_check_device_id(h, &id_ok, &raw_id));
if (!id_ok) { /* real, documented precondition failure -- do not proceed */ }

ESP_ERROR_CHECK(fpga_neural_wait_calib_complete(h, 5000));

// ... build + WRITE_MEM a real network descriptor at word_addr X
//     (not yet built anywhere in this project -- see the open gap
//     above) ...

ESP_ERROR_CHECK(fpga_neural_set_network_base(h, X));
ESP_ERROR_CHECK(fpga_neural_trigger_network_start(h));
ESP_ERROR_CHECK(fpga_neural_wait_seq_done(h, 10000));

// ... READ_MEM the final layer's own output ...
```

## Non-chained variant: the real octet-batching rule

`fpga_neural_submit_batch()` exists specifically to avoid a real,
documented, unrecoverable-without-reset hazard (`docs/FIRMWARE_SPEC.md`
§4.2): every job in a batch must share the same `w_base`/`n_tiles`, and
the batch size must equal `N_SLOTS/2` (read `N_SLOTS` via
`fpga_neural_reg_read(h, FPGA_NEURAL_REG_N_SLOTS, ...)` at startup, do
not hardcode 8). Prefer this helper over calling
`fpga_neural_write_job()` directly in a loop.
