# hardware/v4 — G-esteso MobileFaceNet accelerator (XC7A100T + DDR3 + ESP32-S3)

Whole board closed at 199.34 MHz: one MobileFaceNet inference (raw
112x112x3 image -> 128-value embedding, bit-exact with `model/gen_mfn.c`)
in 460,617 cycles = 2.311 ms = 107.7x the ESP32-S3 (ESP-DL, 248.8 ms).

Buildbook (storia del progetto + riferimento tecnico): [`docs/buildbook/FPGA-Neural-V4-Buildbook.md`](docs/buildbook/FPGA-Neural-V4-Buildbook.md). Il datasheet vero verrà scritto quando la versione generica sarà chiusa e funzionante.
(and `.pdf`; hardware, operation, pinout, ESP32 firmware guide, Italian).
Start here: [`docs/DOCUMENTAZIONE_V4.md`](docs/DOCUMENTAZIONE_V4.md)
(complete reference, Italian). Also: [`docs/COME_FUNZIONA_G_ESTESO.md`](docs/COME_FUNZIONA_G_ESTESO.md)
(how the network runs), [`docs/PINOUT_V4.md`](docs/PINOUT_V4.md) (pins),
[`docs/PROGRESS_LOG.md`](docs/PROGRESS_LOG.md) (step-by-step log),
[`bitstream/`](bitstream/) (ready bitstreams).

| Dir | Content |
|---|---|
| `rtl/` | synthesizable Verilog (board top, boot, QSPI port, core and engines) |
| `sim/` | Icarus and xsim testbenches, `run_icarus.sh` regression |
| `model/` | C golden model and DDR3 image generator (`gen_mfn.c`), cycle model |
| `constr/` | board XDC, core-only P&R script and constraints |
| `vivado/` | project creation, whole-board implementation and real-MIG simulation scripts |
| `bitstream/` | bitstreams (tags `v4-board-199`, `v4-board-189`) |
| `docs/` | documentation and P&R reports |
