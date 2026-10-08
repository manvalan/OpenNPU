# v4 research — depthwise-separable native pipeline ("G-esteso")

Branch: `v4-conv-parallel-research`. Status: **architecture converged, RTL
in progress**. This document is the mathematical/algorithmic record of
the design this session's brainstorm converged on, kept separate from
`docs/` (which describes the real, current `v3-artix7` fabrication
target) per the user's own explicit instruction to keep Passo 2
experimentation in its own branch and area.

Every number below is either directly measured (real Vivado synthesis
or xsim run, this session) or explicitly marked as a projection/citation
from an external source. Nothing is guessed and presented as fact.

---

## 1. Why this direction, and why not Winograd

The original Phase 2 brainstorm explored a Winograd F(2×2,3×3) transform
engine (`winograd_f23_*.v`, still in the repo, fully verified
functionally, kept for reference / possible future use — not deleted).
Real, out-of-context Vivado synthesis of that engine found:

- A single-channel Winograd core with a **constant** (compile-time)
  transformed kernel: **20 DSP48E1**.
- A CIN=4/COUT=4 instance with the kernel left as a runtime port: **272
  DSP48E1 — 113% of the whole XC7A100T's 240-DSP budget**, for one
  engine instance.

This makes a wide Winograd engine impractical on this chip regardless of
how many parallel lanes (`M`) are chosen — even a modest M is DSP-heavy.

**The real reframe**: the actual target workload class (MobileFaceNet-
style face recognition, chosen as the concrete "100x" benchmark — see
§4) is built almost entirely from **depthwise-separable convolutions**,
not the dense, high-spatial-reuse convolutions Winograd is designed to
accelerate. Depthwise-separable convolution has a fundamentally
different arithmetic profile (see §2), and — measured, not assumed — its
own real hardware cost is dramatically cheaper than Winograd's:

- One channel's direct 3×3 depthwise MAC (weight as a real runtime
  port, not even a constant): **0 DSP48E1, 696 LUT** (real, out-of-
  context Vivado synthesis, this session).

Winograd's whole value proposition (reduce multiply count for a spatial
kernel with high reuse) barely applies here: depthwise has almost
nothing to reuse (each channel's own tiny K×K filter, used once per
output position, no cross-channel mixing), and pointwise (§2) has no
spatial kernel at all, so there is nothing for a spatial transform to
act on. Winograd was being built for the wrong kind of network.

## 2. The math: depthwise-separable convolution

A standard ("dense") convolution computes, for kernel size K, Cin input
channels, Cout output channels:

```
out(x, y, co) = act( Σ_{kx,ky,ci} w(kx,ky,ci,co) · in(x+kx, y+ky, ci) + b(co) )
```

MAC count: `K·K·Cin·Cout·Hout·Wout` — this is what §5 of this project's
existing `docs/ARCHITECTURE_ANALYSIS.md` and this session's own G/
Winograd work were built around.

A **depthwise-separable** convolution (Sifre & Mallat 2014; popularized
by MobileNet, Howard et al. 2017) factors this into two much cheaper
stages:

**Depthwise stage** — one independent K×K filter *per channel*, no
cross-channel mixing:

```
dw(x, y, ci) = Σ_{kx,ky} wd(kx,ky,ci) · in(x+kx, y+ky, ci)
```

MAC count: `K·K·Cin·Hout·Wout` — linear in Cin, independent of Cout.
**Very little weight reuse**: each of the K·K weights for channel `ci`
is only reused across that channel's own Hout·Wout spatial positions —
there is no Cout-driven reuse multiplier the way a dense conv or a
pointwise stage gets.

**Pointwise stage** — a real 1×1 convolution, i.e. a per-pixel
fully-connected layer across channels, no spatial kernel at all:

```
out(x, y, co) = act( Σ_ci wp(ci,co) · dw(x, y, ci) + b(co) )
```

MAC count: `Cin·Cout·Hout·Wout`. Structurally **identical** to what this
project's existing, real, timing-closed generic engine
(`packed_pe_chained.v` / `neural_processor_packed.v`, `v3-artix7`)
already computes for a fully-connected layer — weight-stationary,
high reuse (every weight reused across all Hout·Wout positions).

**Combined real cost** (well-established result, Howard et al. 2017 —
cited, not re-derived here): for typical K=3 and large Cout, a
depthwise-separable block needs roughly `1/Cout + 1/K²` of a dense
convolution's MACs — commonly an 8–9× reduction for K=3. This is *why*
MobileFaceNet only needs ~221M total MACs (§4) for a real face-
recognition task, and why real MobileNet-family networks are
**pointwise-MAC-dominated**: pointwise's `Cin·Cout` term usually
outweighs depthwise's `K·K·Cin` term once Cout grows past K² (=9 for
K=3) — a widely-reported property of this network family, not
independently re-verified against MobileFaceNet's own exact per-layer
channel counts in this session.

## 3. The architecture: "G-esteso"

Three ideas from this session's brainstorm turned out to be one design,
not three alternatives:

1. A **specialized engine per bottleneck type**, not per fixed-vs-
   flexible (the original Passo-2 "5+2" framing) — because depthwise
   and pointwise have opposite real bottleneck profiles (§2): pointwise
   is compute-bound (favors the existing wide, weight-stationary MAC
   array), depthwise is reuse-starved (favors a cheap, highly
   channel-parallel unit, not a DSP-heavy one).
2. **Fusing depthwise→pointwise with no memory round-trip** — because
   real depthwise-separable networks *always* use the pair together,
   never depthwise alone.
3. **Computing depthwise inside the window mover itself** (extending
   `g_window_mover.v`, already real and verified — §5) rather than as a
   separate downstream stage.

(3) is a concrete mechanism that delivers (2) as a direct consequence:
if the mover emits data that is *already* depthwise-filtered per
channel, and that output feeds the pointwise engine's input the same
cycle (no write-then-read through BRAM/DDR3), fusion is automatic, not
a separate design decision. (1) remains true in the sense that the
mover-with-depthwise and the pointwise MAC array are two logically
distinct blocks — but they are pipelined as one continuous flow.

### 3.1 Data flow

```
DDR3/BRAM  →  G-esteso (row buffer + per-channel depthwise MAC)  →  pointwise engine (≈ existing N=16 generic engine)  →  output
```

- **G-esteso** extends `g_window_mover.v`'s already-verified row-buffer/
  sliding-window mechanism (4-row circular buffer for the Winograd
  case; for plain depthwise K=3/stride 1 this reverts to the *simpler*
  original K=3-row/slide-1 form, since there is no Winograd tiling
  involved here — one real simplification depthwise-separable brings
  back relative to the Winograd work). At each valid window position,
  instead of handing the RAW window to a downstream neuron, it computes
  the depthwise MAC (§2, one instance of `depthwise_mac3x3.v` per
  channel, real cost 0 DSP / 696 LUT each — §1) and emits the resulting
  **per-channel scalar** (not a raw tile) for that output position.
- **Pointwise engine**: consumes G-esteso's per-channel output vector
  (Cin values, one per channel, for the current spatial position) and
  computes `Σ_ci wp(ci,co)·dw_value(ci) + b(co)` per output channel —
  exactly the existing weight-stationary MAC array's own real job.
  Real, deliberate reuse target: `packed_pe_chained.v` /
  `neural_processor_packed.v`, unmodified or near-unmodified, fed by
  G-esteso instead of a direct DDR3 fetch.

### 3.2 Channel parallelism

Depthwise's own real per-channel cost (0 DSP, 696 LUT) means the real
lever for depthwise throughput is **how many channels run in parallel**
inside G-esteso, not DSP budget. Real, measured LUT headroom: ~36,800
LUTs free (63,400 total − ~26,600 already used by the real chained
system) → at 696 LUT/channel, room for **on the order of 50 parallel
depthwise channel units** before LUT becomes the constraint — far more
than the ~5–6 parallel lanes Winograd's DSP cost would have allowed.
**Caveat, stated honestly**: this is an isolated, out-of-context,
no-timing-constraint measurement (same caveat that made the Winograd
number look better in isolation than in full context) — the real number
once G-esteso is built whole, pipelined, and timing-constrained is not
yet known and must be re-measured, not assumed.

## 4. The real target number

From Espressif's own published ESP-DL benchmark (see this session's own
web research, cited in chat, not reproduced here in full): the default
ESP32-S3 face-recognition model (MFN_S8_V1, almost certainly
MobileFaceNet, Chen et al. 2018 — architecture assumed equivalent, not
independently confirmed identical to Espressif's specific build) takes
**248.8 ms** for the model-compute portion of one inference.

**100× target: ≈ 2.49 ms.**

MobileFaceNet's own published cost: **~221M MACs, ~1M parameters, 4.0MB**
(Chen et al. 2018, cited figures, not re-derived). Real ESP32-S3
throughput achieved for this model: 221M / 0.2488s ≈ **0.89 GMAC/s**.

This project's own real, measured, timing-closed N=16 generic engine
peak: **39.68 GMAC/s** (`docs/ARCHITECTURE_ANALYSIS.md` §3.2, real Fmax-
based figure, unchanged by this session's work). Raw ratio, parallelism
alone, no sparsity, no Winograd: **≈ 45×**.

Per §2's real MobileNet-family property (pointwise-MAC-dominated), most
of MobileFaceNet's 221M MACs are plausibly the pointwise kind — which
maps directly onto this already-real, already-fast 39.68 GMAC/s engine.
The depthwise portion (real 0-DSP, 696-LUT/channel cost) is handled by
G-esteso essentially "for free" relative to the DSP budget, and fused
with no DDR3 round-trip. The ~2.2–2.5× gap remaining to reach 100× was,
in the earlier (standby) brainstorm thread, hypothesized to come from
ReLU activation sparsity (well-documented 50–90%, often 50–80%, typical
range — cited literature figures, ORB "Activation Sparsity" survey and
others found this session, not re-derived) — that hypothesis is
orthogonal to G-esteso and remains open, not yet built or measured.

## 5. Real, already-verified building blocks this design reuses

- `g_window_mover.v` (hardware/v4/rtl) — the incremental sliding-window
  mover, real, verified (21/21 across two parameter configurations,
  200/200 in full mover+neuron integration, 940/940 in the full-image
  writeback test, 330/330 in the two-layer chaining test). G-esteso is
  an extension of this same module's own mechanism, not a rewrite.
- `depthwise_mac3x3.v` (hardware/v4/rtl) — the per-channel depthwise
  MAC, real, verified (2002/2002 against an independent golden model,
  including a real bug found and fixed: the intermediate accumulator
  was initially under-width, caught by deliberately adversarial min/max
  edge cases, not the random trials).
- The real layout convention deliberately shared between
  `g_window_mover.v`'s input and `winograd_writeback_addr*.v`'s output
  (row-major, channel-interleaved) — already proven, in the two-layer
  chaining test, to let one stage's output feed the next stage's input
  memory directly with no reshuffle. The same convention applies here
  between G-esteso's own output and the pointwise engine's input.
- The existing, real, timing-closed `v3-artix7` generic engine
  (`packed_pe_chained.v`, `neural_processor_packed.v`) as the intended
  pointwise-stage reuse target — not yet wired to G-esteso, real next
  step.

## 6. Open questions (real, not yet answered)

1. Real, in-context (pipelined, timing-constrained, many-channel) LUT/
   DSP/Fmax cost of G-esteso — the §3.2 estimate is isolated and must be
   re-measured once built, per this project's own standing discipline
   (a fresh real P&R after every real RTL change that matters).
2. Whether `packed_pe_chained.v` can accept G-esteso's own output
   format directly, or needs a real adapter — not yet checked against
   the actual RTL interface.
3. MobileFaceNet's real per-layer depthwise/pointwise MAC split — §2's
   "pointwise-dominated" claim is a well-known MobileNet-family
   property, not independently verified against this specific
   architecture's own real layer dimensions.
4. The ReLU-sparsity lever (§4, ~2.2–2.5× needed) is completely
   unbuilt and unmeasured — real next step once G-esteso itself is
   working, or a parallel track.
5. Real end-to-end pipeline latency/throughput once G-esteso feeds the
   real pointwise engine — not yet measured, only reasoned about.
