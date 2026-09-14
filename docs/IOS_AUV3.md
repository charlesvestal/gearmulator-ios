# JE-8086 on iOS / iPadOS

Status: the AUv3 builds, signs, installs and plays. It is **marginal** — around
1.0x real time sustained, with occasional dips — and every number below was
measured on an M5 iPad Pro unless stated otherwise.

## The one-line summary

There is no JIT on iOS, the interpreter is ~20x slower than the JIT, and the
gap that leaves is small enough to be decided by *scheduling* rather than by
the emulator's speed.

## Things that are settled, so nobody re-derives them

**The JIT is closed on iOS.** asmjit can MAP an executable page — the probe
succeeds and reports the JIT as available — and then the kernel SIGKILLs the
process the moment it EXECUTES generated code. The probe cannot discover this
by trying, because trying is what kills you. iOS is therefore opt-in
(`JE_FORCE_JIT=1`), for a dev-signed build under a debugger, where
CS_DEBUGGED permits execution. asmjit also does not compile for iOS as
shipped: `virtmem.cpp` gates `<libkern/OSCacheControl.h>` on `TARGET_OS_OSX`
while `flushInstructionCache()` calls `sys_icache_invalidate()` on all Apple
targets.

**Four pipeline stages, not three.** 4-stage 0.99x, 3-stage 0.68x, 2-stage
0.31x. The Pi finding that "three stages beat four in a host" does NOT
transfer: with the interpreter a 3-way split must put two ASICs on one stage,
and that stage becomes the bottleneck.

**ASIC3 is the bottleneck, not the H8S.** Per-stage, interpreted:

    Stage 0 (H8S+ASIC0): 7.64 us/sample   out-wait 0.45 s
    Stage 1 (ASIC1):     4.99             out-wait 2.22 s
    Stage 2 (ASIC2):     5.48             out-wait 2.08 s
    Stage 3 (ASIC3):     7.89             out-wait 0.05 s
    Budget:             11.34

ASIC3 executes 38% more real instructions than ASIC1/2 (851M vs 618M per 10 s
render) because that is what its program does. A single ASIC cannot be split
across stages: the two ESP cores interleave per cycle and they share GRAM.
So the pipeline ceiling is ASIC3's stage time, ~1.44x, and no rebalancing
changes it. A 5-stage split (H8S alone) works but is slower — 0.84x — because
five stages need five performance cores and this class of hardware has four.

**The interpreter is near its floor.** +35% banked and bit-exact (nop run
skipping, and decoding the MAC family as bit fields). Seven further attempts
measured and REJECTED — see the comments in esp.hpp. The rule that emerged:
removing an indirect branch for a whole class pays; adding a compare in front
of a case that still ends in the jump table does not, because the ESP program
is a fixed 768-word loop the branch predictor learns.

Correctness-breaking probes put the remaining cost where it is:
storePipeline x2 = 8%, multiply/accumulate = 6%, op handling = 35%, and most
of that 35% is the work in the op bodies rather than dispatch.

## Scheduling is the difference between working and not

The engine used to decline from ~1.48x to ~0.96x over the first minute and
stay there, with the workload flat (the ESP program is fixed; all voices are
always computed) and `NSProcessInfo.thermalState` reporting **nominal**
throughout. 1.48/0.96 = 1.54, about the P-to-E core ratio.

`thermalState` is no evidence either way: DVFS and core-type recommendation
happen well below the threshold that raises it.

What fixed it:

- **Realtime policy AND the workgroup, in that order.** "Only real-time
  threads can join an audio workgroup", so `THREAD_TIME_CONSTRAINT_POLICY`
  first, then `os_workgroup_join` with a **thread_local** token. Tested
  separately, each disappoints and each looks like a dead end: RT alone is
  worse, the workgroup alone does nothing.
- **Never `yield()` on Apple.** `sched_yield()`/`this_thread::yield()` makes
  the scheduler migrate the thread to an efficiency core. A pipeline stage
  that yields on every handoff volunteers for demotion 88200 times a second.

Result: 55/171 seconds below 1.0x instead of 190/216, holding 1.01-1.03x with
`underrun 0` for minutes at a time.

There is **no thread affinity API on Apple silicon**. `THREAD_AFFINITY_POLICY`
returns KERN_NOT_SUPPORTED; Apple DTS says there is no supported way to bind
to a core class. The levers are RT policy + workgroup, QoS, and keeping the
hot thread count at or below the P-core count.

**Next thing to try:** this pipeline is ASYNCHRONOUS — it runs ahead of the
render callback — and Apple's guidance for that case is a custom workgroup
from `AudioWorkIntervalCreate` driven with `os_workgroup_interval_start` /
`_finish` every cycle, rather than joining the device workgroup. Async threads
that only join are invisible to the performance controller.

## Plugin hygiene bugs found here (three are upstream, not iOS-specific)

- `Device::processAudio` popped per sample from a BLOCKING ring. A slow engine
  did not go quiet, it stalled the host's whole render graph — in AUM nothing
  else made a sound until the app was force-quit.
- `JeThread::processSamples` pushed to a 32-deep BLOCKING job ring. Once full,
  `push_back` stalls the audio thread, which makes the host later, which
  deepens the backlog: self-sustaining, so the plugin plays cleanly and then
  breaks up for good.
- `Processor::setDspThreads()` clamps against `getMaxDspThreads()`, which
  answers 1 while there is no device — and the documented time to set it is
  BEFORE the device exists. Every value above 1 was silently discarded.
- `latencyBlocks` defaults to 1, giving a four-stage pipeline one host block of
  runway. iOS uses 8.
- `RmlUi_Renderer_GL3` passed `GL_R` as a glTexImage2D format. It is `GL_RED`
  on every platform; only iOS notices, because its headers omit `GL_R`.

## Bounded backlog: recover instead of running away

Capacity is not constant. When it dips below 1.0x, every queued sample is
stale audio that still has to be rendered, so an unbounded backlog means the
periods above 1.0x are spent working off history and never catch up — one dip
becomes permanent breakup. Measured at 35515 and 57389 samples of carry with
the ring pinned empty. `m_maxCarrySamples` bounds it: past the threshold, drop
the backlog and render NOW. One discontinuity, then a clean stream. MIDI is
kept, or notes would stick on.

## Measuring on the device

An AUv3 has no console, so `jeDiag()` writes to a file in the extension's
container (`devicectl device copy from --domain-type appDataContainer`) and
echoes to stderr. `JE_SELFTEST_CHORD=1` makes the standalone play itself a
six-note chord two seconds after boot, so a LOADED measurement needs no host,
no keyboard and no human.

Traps that produced wrong answers here, all of them more than once:

- **`engine made` is demand-limited** and can only ever equal `host wanted`.
  It says nothing about capacity. The honest instrument is ns/sample timed
  around the render loop, and the ring depth.
- **11337 ns/sample is exactly real time at 88.2 kHz**, and reading it is
  suspicious rather than reassuring: when the ring is FULL the engine blocks
  pushing audio and measures exactly demand. Capacity readings are only valid
  when the ring is not full.
- **A locked device refuses every launch** (`FBSOpenApplicationErrorDomain
  error 7`), and a script that copies the diagnostics afterwards will happily
  copy the PREVIOUS run's file. Require proof the run happened — the self-test
  marker in the console — and check the file actually changed.
- **Benchmark on an idle Mac.** Numbers taken while device sweeps were running
  had to be re-taken against a reference build under identical load.

`jeDiag()` and the self-test chord are diagnostic scaffolding and should be
removed or gated before release.

## Which devices this runs on

**M-series iPads. Not iPhones, and not A-series iPads.**

| device class | chip | P-cores | verdict |
|---|---|---|---|
| iPad Pro / Air | M1, M2 | 4P + 4E | should work (inferred) |
| iPad Pro | M4, M5 | 3-4P + 6E | **works -- measured on M5** |
| iPhone, ANY model | A-series | 2P + 4E | **underruns -- measured on A17 Pro** |
| iPad (base), iPad mini | A-series | 2P + 4E | won't: same topology as the phone |

Measured: an M5 iPad Pro runs two simultaneous instances at 98-99% clean. An
iPhone 15 Pro underruns, and does so at TWO stages and at FOUR alike, so the
stage count is not what stops it.

Inferred: M1/M2 iPads should be fine. The interpreted engine measures 0.70x
serial and 2.07x pipelined on an M1, which is the same CPU as the M1 iPad Pro.
That is a same-family measurement rather than a spec-sheet guess, but it is
still not a test on the hardware.

**No future iPhone fixes this.** Every A-series chip from the A11 to the A18 Pro
has exactly two performance cores; the topology has not moved in seven
generations. The A17 Pro's P-cores are individually FASTER than an M1's and it
still underruns, so this is not about per-core speed -- serial sits below real
time, the only way up is spreading stages, and two performance cores caps how
much of that can be recovered.

Do not read that as "the E-cores are useless": deriving the stage count from
`hw.perflevel0.physicalcpu` to keep every stage on a P-core made the IPAD worse
(three stages could not hold two instances that four handled), so the efficiency
cores are carrying real work. The phone's problem is the total, not the mix.
