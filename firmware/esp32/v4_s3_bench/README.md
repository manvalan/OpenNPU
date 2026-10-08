# v4_s3_bench — the same network on the ESP32-S3 CPU

Runs a network on the ESP32-S3 with the **exact integer arithmetic of the
FPGA** (`main/v4net.cpp`, C++ twin of `hardware/v4/model/v4_ref.py`):
same requantization (round half up, saturation), ReLU/PReLU, residual
add, pooling. The output must be **identical byte for byte** to the
FPGA's, and the app prints the time per inference.

It is plain portable C++ (integer loops, no SIMD, no ESP-DL): the time
is what a straightforward CPU implementation costs, not ESP-DL's
optimized kernels (ESP-DL rounds differently, so its values would not
match the FPGA bit for bit).

## Use

```
./make_net.sh bench_heavy          # or bench_small, bench_medium, mfn, any v4_plan example
idf.py set-target esp32s3 build flash monitor
```

`make_net.sh NET` makes a random calibrated model (as `v4_qat.py
--selftest`) and writes `net/net.bin` (network, parameter pack, input,
expected output) plus `net/model.pack` and `net/img.bin`, the same files
`v4_compile.py` / `make_model.sh --net` take for the FPGA.
`make_net.sh NET model.pack img.bin` uses your own trained model.

Output (serial monitor):

```
I v4_s3_bench: run 0: ... ms, output identical to the FPGA
...
I v4_s3_bench: RESULT: best ... ms, mean ... ms over 5 runs, 5/5 bit-exact, peak activations ... bytes
```

Needs an ESP32-S3 with 8 MB flash and PSRAM (octal, as on the
ESP32-S3-DevKitC-1 N8R8; for quad PSRAM set `CONFIG_SPIRAM_MODE_QUAD`).
Large activations go to PSRAM, the rest to internal RAM.

## Check on a PC first

```
g++ -O2 -Imain host/main_host.cpp main/v4net.cpp -o v4net_host
./v4net_host net/net.bin 3
```
