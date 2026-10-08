# espdl_v4 — the v4 networks with ESP-DL on the ESP32-S3 (accelerated)

The accelerated counterpart of [`../esp32s3_v4/`](../esp32s3_v4/): the same
four networks run with **ESP-DL 3.3** (Espressif's library, which uses the
S3's SIMD/PIE instructions), on one core and on both cores. ESP-DL needs
its own quantization (ESP-PPQ: per-tensor power-of-two exponents, its own
rounding), so **the output is not bit-exact with the FPGA**: the app reports
the time and the raw output, and `compare.py` measures how close it is.

| Path | Content |
|---|---|
| `export_espdl.py` | NET -> `models/NET/model.onnx` (float, standard layers) -> `model.espdl` (ESP-PPQ, 8 bit, esp32s3) + `meta.json` |
| `models/NET/` | the exported models (also `model_ort_int8.onnx`, used by `../linux_v4/ort/`) |
| `models/espressif_mfn/` | Espressif's own trained MobileFaceNet (`human_face_recognition` 0.3.2, MIT), timing only |
| `firmware/` | ESP-DL bench app: `model->test()`, 10 runs on 1 core (`CSV`), 10 on 2 cores (`CSV2`), output dump (`OUT`) |
| `run_espdl.sh` | build + flash + capture for each model, then `stats.py` (`summary.csv`, `summary_CSV2.csv`) and `compare.py` |
| `compare.py` | `accuracy.csv`: output vs float and vs the FPGA's INT8 output |
| `results/<date>_<board>_espdl/` | raw serial logs + CSVs |

The model is the same network as the measured `net.bin`: `export_espdl.py`
rebuilds `v4_qat.random_model(NET)` and checks its INT8 pack against the
`net.bin` (identical for small and medium; 33 / 4 bytes of 2.8 MB / 1 MB
differ for heavy / MFN, float rounding on another machine), and checks the
ONNX graph against the QNet float forward in float64.

Checks on the board: `model->test()` compares ESP-DL with ESP-PPQ's own
simulation on the exported test input (PASS for the four v4 models; the
Espressif model ships without test values), and the dumped output equals
the ESP-PPQ test output.

Accuracy caveat: the networks are **random** (seeded, calibrated, not
trained). On the deep ones (heavy, MFN) even the FPGA's bit-exact INT8
output is far from the float output (cosine 0.04 / 0.64), so accuracy
numbers are only meaningful for bench_small; the comparison here is about
time.

## Run

```
python3.11 -m venv ~/venvs/espdl && ~/venvs/espdl/bin/pip install torch onnx onnxruntime numpy ml_dtypes esp-ppq
~/venvs/espdl/bin/python export_espdl.py bench_small models/bench_small      # (done, committed)
PYNUM=~/venvs/espdl/bin/python ./run_espdl.sh /dev/cu.usbmodem1201 results/$(date +%F)_<board>_espdl
```

Firmware config (`firmware/sdkconfig.defaults`, Espressif's recommended
settings for ESP-DL): 240 MHz, octal PSRAM 80 MHz, QIO flash 80 MHz,
64 KB data cache with 64-byte lines, 15 MB app partition.

Report: [`docs/benchmarks/ESP32S3_V4.md`](../../docs/benchmarks/ESP32S3_V4.md).
