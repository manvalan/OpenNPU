# linux_v4 — v4 networks on a Linux board (e.g. Raspberry Pi)

Same `v4net.cpp` (FPGA integer arithmetic) and same `net.bin` inputs as
[`../esp32s3_v4/`](../esp32s3_v4/), run by the Linux build of the host
runner (`../esp32s3_v4/firmware/host/main_host.cpp`, one `CSV,run,us,bit_exact`
line per run, `std::chrono::steady_clock`). The board compiles it itself
with its own `g++ -O2`; single thread.

```
./run_ssh.sh user@host results/$(date +%F)_<board>
SSHPASS=... ./run_ssh.sh user@host ...    # password login (needs sshpass)
```

`run_ssh.sh` copies the sources and nets to `~/v4bench` on the board,
builds, records the board identity (`board.txt`: model, kernel, compiler,
clock, temperature, throttling), runs each network 10 times and writes
`runs.csv` / `summary.csv` with `../esp32s3_v4/stats.py`.

Report: [`docs/benchmarks/ESP32S3_V4.md`](../../docs/benchmarks/ESP32S3_V4.md).
