# Machinedrum and Monomachine on iOS

Status: **Neither instrument is functionally validated on the M5 iPad.**
Machinedrum clears the initial DSP livelock but remains on its boot logo;
Monomachine passes its logo and produces samples after trigs, but the user
reports no audible output from the device app.
Measured 2026-09-16, arm64, no JIT.

MD/MM are not part of this tree. They live in
[joelanders/gearmulator-md-mm](https://github.com/joelanders/gearmulator-md-mm),
a fork that sits on the pre-reorg upstream layout (flat `source/`, no
`source/framework` or codename directories) and has no iOS support. Everything
below was done in a scratch clone of that fork. The portable source changes are
preserved in `patches/md-mm-ios.patch`; firmware and build products are omitted.

## What the hardware is

`md::Hardware` models an Elektron ColdFire MCU at 40 MHz plus **two DSP56303s**
at 101.6064 MHz, and -- this is the part that matters -- advances all three
from a single deterministic interleave scheduler **on the calling thread**.
DSP2 is the voice producer, DSP1 is the mixer that drives the codec and whose
ESSI frame counter is the master clock the MCU is paced against.

So it is one thread for two DSPs and an MCU, where NodalRed2x already gives each
of its two DSPs a thread of its own.

## Two fixes to build it for iOS

Both are in the fork, not here:

**`source/dsp56300/source/dsp56kBase/cowmemory.cpp`** guards its Mach VM code on
`__APPLE__`, but `mach_vm_remap` and `mach_vm_deallocate` are not exposed by the
iOS SDK, so the guard compiles on macOS and fails on the device. It needs to be
macOS-specific; iOS then takes the `return false` path that
`MmuArray::initFromTemplate` already handles. This file does not exist in our
fork of dsp56300 at all.

**`source/dsp56300/source/asmjit/src/asmjit/core/virtmem.cpp`** is the
`sys_icache_invalidate` gating bug already described in `IOS_AUV3.md` -- the
header is included under `TARGET_OS_OSX` while the call happens on every Apple
target. Our fork already carries the fix; theirs does not.

With those two, `mdLib` builds, signs and runs on iOS/arm64.

## What it does on an M5 iPad

```
[boot] audio 0.25s  slice 0.12s (2.1653x)  dspInstr mixer 5.05M producer 5.04M
[boot] audio 0.50s  slice 0.12s (2.0315x)  dspInstr mixer 5.07M producer 5.07M
[boot] audio 0.75s  slice 0.14s (1.8328x)  dspInstr mixer 5.07M producer 5.07M
[boot] audio 1.00s  slice 0.14s (1.8000x)  dspInstr mixer 5.07M producer 5.07M
MONITOR +2.0s  mixer 0.000M instr/s  producer 205.256M instr/s
MONITOR +2.0s  mixer 0.000M instr/s  producer 200.730M instr/s
MONITOR +2.0s  mixer 0.000M instr/s  producer 197.938M instr/s
```

This was the diagnostic trace that exposed the original livelock. The
1.8-2.2x figures cover only the pre-stall boot phase and must not be treated as
the final result. Then the mixer DSP stopped -- exactly zero instructions per
second -- while the producer ran flat out indefinitely. The whole stall lived
inside a single `process()` call.

Reproduced identically on an idle M1 desktop (producer ~95M instr/s, mixer 0),
so it is neither machine load nor a device limit.

## Why it was a livelock and not a slow interpreter

Instruction counts, not timings, settle this. For the same emulated second:

| build | mixer | producer | outcome |
|---|---|---|---|
| JIT | 68.5M | 75.1M | completes |
| interpreter | 0 | 8.5 billion and counting | never completes |

About 100x more emulated work for identical audio. The two builds are therefore
**not emulating the same thing** -- this is a divergence in emulated timing, not
a wall-clock difference.

The cause was the interpreter's handling of a hardware `DO` loop. A single
`DSP::exec()` recursively executed the whole loop. MD/MM's scheduler expects an
`exec()` call to yield so it can interleave the ColdFire MCU, mixer DSP, and
producer DSP. During the boot handshake, one DSP waited for an MCU write while
the MCU could not run until that same `exec()` returned.

When `maxDoIterations` is configured, the interpreter now yields after setting
up the hardware loop and resumes it in bounded slices. A regression test covers
that bounded-yield behavior, and the dsp56k test runner passed. This removed
the original boot livelock, but it did not establish functional firmware boot:
the MD panel test fails in interpreter mode, and an MM host audio test reports
invalid DSP memory reads.

## Current performance after the fix

The fork's `mdmm-v0.1.0-alpha.12` is already the scratch clone's base. Its speed
work is enabled only when the Apple ThinLTO and DSP optimization CMake switches
are on; the first iOS plugin builds had both switches off.

With ThinLTO and a fresh profile trained on both firmware workloads:

| product | M5 iPad result | conclusion |
|---|---:|---|
| Machinedrum | 2.416x measured throughput; 4.64 s bench warmup | panel boot fails in interpreter; not usable yet |
| Monomachine | 0.71-0.79x | passes logo and produces samples after trigs; no audible device output reported, and misses real time |

MM needs about 82M interpreted instructions per second from each DSP. The
profiled build reaches roughly three quarters of the required aggregate work.
Time Profiler shows a broad interpreter and scheduler workload rather than a
new hang. Further MM work therefore needs an architectural speedup, with
parallel DSP execution the main candidate; that requires preserving the
existing deterministic DSP/MCU handshake.

## What this means for a port

The MD logo failure is not explained by raw CPU throughput. An M5 iPad
sustains ~200M DSP instructions/sec per DSP in the bench, but the functional
firmware path diverges in interpreter mode. The work is:

1. Upstream the bounded hardware-loop interpreter fix and the iOS compatibility
   changes preserved in `patches/md-mm-ios.patch`.
2. Fix MD's interpreter panel boot. On the actual iPad, both DSP cycle counters
   advance and the MCU reports audio, panel handshake, and MIDI readiness, but
   panel output stops at 3,160 bytes and 314 tile writes. The same firmware
   panel test passes with JIT (26,894 bytes) and fails with the interpreter.
   Host checkpoints agree exactly through 1.0 emulated second: both DSPs have
   the same PCs, instruction counts, and cycle counts. By 1.1 seconds the
   producer DSP differs inside its program-upload loop at `P:0x14ff1b`;
   by 1.2 seconds JIT is executing uploaded code at `P:0x100095` while the
   interpreter is still in the loader. The JIT frame-sync fast-forward path
   did not run before this divergence, and selecting the older scheduler
   dispatcher did not change the interpreter result. This narrows the next
   investigation to execution timing after the upload: both DSPs have matching
   program-memory hashes across `P:0x100000`-`0x11ffff` in JIT and interpreter
   at 2.0 seconds. Around 2.6 seconds,
   the interpreter mixer stops draining host RX words. Its 100,000-cycle
   per-word receive clamp then fires repeatedly and advances the DSP about
   25 million cycles ahead of the shared clock; JIT has no such clamp hits.
   The resulting panel stall is a transport symptom, not a slow boot animation.
3. Trace MM's silence downstream of the panel input. In the instrumented iPad
   app, Trig 1 presses and releases were accepted by the editor and delivered
   to firmware as UART row `0x20` masks `0x01` and `0x00`. Its main stereo
   buffer reached peaks of about 0.04-0.11 after those taps, so the touch
   mapping and sample generation both work. The iPad startup log also confirms
   real firmware progress:
   panel output grows from 3,140 to 27,554 bytes and LCD pixels change over
   roughly 20 seconds. Yet the interpreter device run emitted over six million
   invalid DSP memory-read diagnostics during the capture and advanced less
   than one emulated second per two wall-clock seconds with diagnostic logging.
   An interpreter host sine test also began reporting invalid DSP memory
   reads, while a JIT comparison produced no such reads during a 45-second
   observation; neither run completed that longer audio test within the
   observation window. Check the final standalone audio route and resolve the
   interpreter faults and speed deficit before treating MM as usable.
4. Replay any remaining product-level iOS refinements from this tree, including
   editor sizing and rotation, as they become observable in device testing.

## Reproducing

Build the bench as an iOS app per `IOS_BENCH.md`. For MD the instrumentation
that mattered was a monitor thread sampling
`device->getHardware().getDspMixer().dsp().getInstructionCounter()` and the same
for `getDspProducer()`, printing per-DSP instruction rates every two seconds --
the only thing that distinguished the livelock from a slow interpreter, because
per-block instrumentation never fires when the stall is inside one block.

The ROMs are fingerprinted: `md::RomLoader` accepts exactly one 8 MiB image per
product, MD OS 1.63 (`0x33b7c1a9e29f43fd`) and MM OS 1.32b
(`0xe1c1b461b6d0f21b`), by FNV-1a over the whole file.

## Why the interpreter cannot run MD's transport (2026-09-16)

Every other DSP56300 synth in this tree runs interpreted on iOS. MD/MM do not,
and the reason is architectural rather than a tuning problem.

**The working synths never advance a DSP from the MCU's thread.** Xenia's
host-port write is the whole of its interpreter path:

```cpp
void DSP::hdiTransferUCtoDSP(dsp56k::TWord _word)   // xtLib
{
    if (hdi08().dataRXFull())
        m_hardware.resumeDSP();   // wake the DSP's OWN thread
    hdi08().writeRX(&_word, 1);   // post the word and return
}
```

`xtHardware` gives each DSP a `dsp56k::DSPThread`. MD states the opposite --
"There are no background DSP threads" -- and interleaves the ColdFire and both
DSP56303s on one thread, so every host-port touch must advance the DSP inline:

```cpp
void Dsp::hdiTransferUCtoDSP(const uint32_t _word)   // mdLib
{
    m_hardware.schedCatchUpDsp(m_index);
    writeWordToDsp(_word);        // runs the DSP up to 100k cycles
}
```

Inline advancement only produces correct behaviour if it reproduces the JIT's
timing, and the interpreter cannot. Measured during MD boot:

| path | DSP cycles contributed | clamp hits |
|---|---:|---:|
| `hdi08[mixer]` (`writeWordToDsp`) | 57,698,692 | 550 (max 100,050) |
| `hdi08[producer]` | 41,890,152 | 57 |
| `cf->dsp[mixer]` (`schedCatchUpDsp`) | 30,858 | 0 -- "already at target" on 116,963 of 117,574 calls |

`schedCatchUpDsp` checks the machine clock and therefore almost never advances
anything. `writeWordToDsp` does not, so it runs a DSP 100,000 cycles into the
future per host word. The mixer reached **15.7M cycles ahead** of the ColdFire
by tick 40 -- uc/dsp 0.3792 against the correct 0.3937, a ratio the JIT holds
exactly. That desynchronises the ESSI link: the producer transmits while the
mixer's receiver is still disabled, **73,702 frames are dropped (`rxDisabled`)**,
the producer->mixer ring jams at **512/512**, and the panel freezes.

Clamping that drain to the machine clock removes the drift (0.3939) and moves
the panel past its plateau (3160 -> 3380 bytes, mixer reaching 0x9da, the JIT's
panel region) but does not boot: refusing to advance at all deadlocks, and a
bounded allowance is a heuristic over a structural mismatch. A slack sweep
confirms it is not a tunable: 256 is worse than 2048.

**The fix is to give MD's DSPs their own threads, as every other synth here
already does.** That also closes MM's throughput gap, since two DSPs on two
cores is the ~2x it needs. It is a substantial change to a deliberately
deterministic scheduler and belongs upstream.

### Fixed along the way (in `patches/md-mm-ios.patch`)

- **`do_exec` accounting.** The bounded-DO early return skipped the cycle and
  instruction accounting for the `DO` instruction itself, so it was free in the
  interpreter and charged in the JIT. This made emulated results depend on
  `maxDoIterations` -- 4 and 64 computed different things, which a scheduling
  knob must never do. With it fixed, bounded and unbounded runs produce
  identical instruction *and* cycle counts at every tick, and bit-identical
  instruction streams over 1.5M instructions. It also moved the producer onto
  the JIT's path (uploaded code at `0x100095` instead of bailing to `0xbb`) and
  took the inter-DSP link from **zero frames in both directions** to 1.6M/1.16M.
- **Rate-limited `LOG_ERR_BASE`.** A per-instruction firmware fault emitted
  3.48M lines (162 MB) in 90 seconds on device, where formatting and writing
  them dominated the run and blocked the realtime audio thread. First few per
  site, then silent counting: 162 MB -> 14 KB. This is what made MM audible.

### Disproved, so nobody repeats them

- The bounded-DO loop epilogue is **not** mis-implemented: both DSPs' traces are
  bit-identical to the unbounded interpreter's.
- The ESSI clock is **not** instruction-driven for MD: it already selects
  `ClockSource::Cycles`.
- Matching the JIT's block granularity in the interpreter does not help -- real
  JIT blocks end at branches, so a fixed 32-instruction slice matches nothing.
- Disabling bounded DO entirely (`maxDoIterations=0`) livelocks, so the bounded
  yield is required, not optional.

### Threads are required, and gating alone is not enough (measured)

Two experiments settle what the fix has to be.

**Removing the inline advance without a thread deadlocks.** `MD_HDI08_POST_ONLY=1`
makes the host-port write post the word and return, exactly as xtLib does. MD
stalls at tick 24, identical to refusing the advance outright. With one thread
there is a circular dependency: the scheduler will not advance the DSP because
it has reached its frame-derived clock target, the clock only advances when
audio frames are produced, and frames require the DSP to run. Inline
advancement is what breaks that circle today -- badly.

**Gating the scheduler and adding a DSPThread is necessary but not sufficient.**
`MD_DSP_THREADS=1` gives each `md::Dsp` a `dsp56k::DSPThread` at boot (where
`xtDSP::onDspBooted` creates its own) and skips the three sites that would
otherwise execute the same DSP twice: the background quantum in `schedStep`,
`schedCatchUpDsp`, and the inline drain in `writeWordToDsp`. The threads start
and run -- the mixer reaches uploaded code at `0x10009c` and emits samples,
which the single-threaded interpreter never managed -- but the machine stalls
at tick 29, `bytes=3146`.

That is expected: `Hardware::advance()` still drives the machine clock and the
host audio queue on the scheduler's terms while the DSPs now run free, and the
ESSI link, the MD rendezvous handshake and MM's transmit backpressure all still
assume scheduler-mediated execution.

**So the remaining work is the real one:** rework `schedStep`/`advance`
(~350 lines) so the host audio queue is fed by the mixer's ESSI TX from its own
thread and the ColdFire coordinates through the HDI08 rather than by stepping
DSPs, as every threaded synth here already does. That necessarily gives up the
determinism this scheduler was built for, which its own tests assert, so it is
a decision for the fork rather than a patch from outside it.

Both switches are in the patch and default to off, so the existing path is
unchanged.

### Threaded prototype: state at end of 2026-09-16

`MD_DSP_THREADS=1` (default off) gives each `md::Dsp` a `dsp56k::DSPThread` and
the machine is **stable**: 180 ticks, no deadlock, no crash, no race, both DSPs
executing (mixer ~42 MIPS, producer ~12-19 MIPS). The mixer reaches `0x9da/0x9db`
-- the JIT's own panel-driving region, which the single-threaded interpreter
never reached. It still does not boot: the producer ends in its error loop at
`0xbb-0xc0` and the panel stops at 3,160 bytes (JIT: 26,894).

Making it stable required finding every place the old design used *inline DSP
execution* as implicit synchronisation. Seven sites execute a DSP from the
ColdFire thread; all must defer to that DSP's own thread:

  mdhardware.cpp  schedStep background quantum, schedCatchUpDsp,
                  schedCatchUpDspToDsp
  mddsp.cpp       writeWordToDsp, onUCRxEmpty, waitForHostCommandIdle,
                  hdiSendIrqToDSP

**Gate only the execution, never the side effects.** Guarding whole functions
broke the machine in ways that looked like emulation bugs: an early return in
`onUCRxEmpty` skipped `notifyHostPumpStateChanged()`, and in `hdiSendIrqToDSP`
it skipped `dispatchHostCommandInterrupt()` -- the host commands that drive the
bootstrap loader.

Shared state that assumes a single owner:

  - `HostAudioQueue::emplace` pops when full, so its producer mutates both ends.
    Two threads touching it segfaults. The mixer thread is the natural owner --
    `onEssiCallbackMixer` already drains on that thread -- with a staging vector
    handed to the host callback under a short lock.
  - Never hold that lock across `advance()`/`writeRX`; both block, and the
    drain then cannot run. That deadlocks.
  - `DSPThread` runs 128-instruction batches under its own mutex, so any
    per-instruction reach across from the ColdFire thread thrashes it:
    8.7 MIPS against 58 when draining per instruction rather than periodically.

Still missing, and the likely reason the producer fails: the single-threaded
path guaranteed a host command was consumed by running the DSP inline right
after dispatch. xtLib instead waits (`ucYieldLoop` on `hasPendingInterrupts`).
A bounded version of that wait is in place but is not sufficient on its own --
the rendezvous handshake and link delivery still derive DSP position from
`m_schedDspOriginLatched`/`schedDspFramePos`, which are meaningless once the
DSPs no longer advance on the scheduler's terms. Those need to become
event-driven off HDI08/ESSI state.

Note also: the machine-clock clamp on `writeWordToDsp` removes the 15.7M-cycle
drift but **breaks the producer's upload** -- it reaches `0x100095` with the
`do_exec` accounting fix alone and bails to `0xbd` once the clamp is added. The
clamp is therefore not a free win and is left behind its own switch.

### The decisive comparison: what actually differs (2026-09-16, late)

Two controls reframe everything above.

**1. Threading is not the answer, and my threading was broken.** Running the
threaded path with the *JIT* -- a configuration that passes cleanly at 26,894
bytes without threads -- fails identically to the interpreter (3,160 bytes,
producer at `0xbb`). So the threading changes break a known-good configuration
on their own. Every interpreter-focused fix made after threading was enabled
was aimed at the wrong layer.

MD also does not need threads: it benches at **2.4x real time interpreted**.
Threading was pursued from an inference (post-only writes deadlock, therefore
inline advancement is load-bearing, therefore threads) that does not survive
the control. MM needs the speed; MD needs correctness.

**2. The real difference is 20 words in the mixer's program.** Single-threaded,
comparing the uploaded program memory directly:

| | mixer (dsp0) | producer (dsp1) |
|---|---|---|
| JIT (passes) | 404 words | 125,648 words, hash `1e7a88cba19ce116` |
| interpreter  | **424 words** | 125,648 words, hash `1e7a88cba19ce116` |

The producer's program is **byte-identical**. Every word the two mixers share is
also byte-identical. The interpreter simply writes **~20 extra contiguous words**
starting at `P:0x101327`, past where the JIT stops. The mixer therefore runs a
program the JIT never produced, stays in ROM at `0x9da`, and the producer waits
forever in its ISR at `0xbb` for a mixer that cannot answer. That single
difference explains every downstream symptom.

This rules out, with evidence rather than reasoning: host-word delivery, HDI08
ordering, the loader path, and the producer entirely.

**Not the cause:** the bounded-DO epilogue's condition. Requiring that the
instruction just executed really was the loop's last (`pcCurrentInstruction ==
la`, not merely arriving at `la+1`) leaves the program at 424 words. A
stack-level guard mirroring the original `sc >= stackCount` cannot be expressed
as a single scalar -- nested loops overwrite it and the PC runs off (SIGSEGV).

**Where to look next:** why the mixer's upload runs 20 words long. The host word
count delivered to the mixer varies between runs (18,000-24,000), so the upload
length is not deterministic in the interpreter -- which points at a
timing-dependent termination condition in the loader rather than at loop
control. Dump `MD_PWORD` from both engines and diff; the first divergent
address is `0x101327`.

### Confirmed divergence, measured at the same machine time

The earlier program-memory comparison was not controlled -- the JIT dumped after
passing, the interpreter after failing -- so part of the gap could have been
progress rather than error. `MD_SNAP_TICK=30` now snapshots the mixer's P memory
at the same tick in both engines. The divergence is real:

| at tick 30 | mixer P words |
|---|---|
| JIT (passes) | 202 |
| interpreter  | **424** |

  addresses only in the JIT : 0
  shared addresses differing: 0
  addresses only in the interpreter: **222**, contiguous from `P:0x101327`

So the interpreter writes a strict superset. Every word they share is identical;
the interpreter additionally deposits 222 words the JIT never writes, and the
values are a wave table -- `af, 1b5, 2ba, 3bf, 4c3 ... a20`, then `ff8c4f,
feeee7` wrapping negative -- not code. Table data is landing in PROGRAM memory.

Checked and excluded: the same table does not appear in the JIT's X or Y memory
at `0x1300-0x1400`, so this is not a simple memory-area mis-selection at that
address.

That single difference accounts for every downstream symptom: the mixer runs a
program the JIT never produced, stays in ROM around `0x9da`, never drives the
panel past ~3,160-3,380 bytes, and the producer -- whose own uploaded program is
byte-identical to the JIT's, hash `1e7a88cba19ce116`, 125,648 words -- waits
forever in its ISR at `0xbb` for a mixer that cannot answer.

**Next step:** find what executes those writes. Trap writes to `P:0x101327` in
the interpreter (the trace hook in `dsp.cpp` takes a PC trigger) and identify the
instruction and the code path; then compare that path against the JIT, which
never takes it by tick 30.

### Latest correction: write trap and accounting audit (2026-09-16)

Read **[MD_INTERPRETER_HANDOFF.md](MD_INTERPRETER_HANDOFF.md)** next. It supersedes
several conclusions above. The scratch checkout survives. The experimental
clock clamp actually defaults ON in saved source/patch; setting
`MD_HDI08_SLACK=1000000000` disables its effect for these tests. Without it,
both engines have202 mixer P words at tick30, while interpreter boot still
fails. The222 extra words were traced to `move a,x:(r2)` / `move b,x:(r3)` at
0x42d/0x42e: audio data in external memory bridged into P, not an established
program-upload overrun.

A second verified accounting defect was fixed: execOp charged bounded DO again
after do_exec had charged it. Existing cycle test failed before correction;
interpreter unit suite passes after it. Boot remains broken at3160 bytes
(JIT passes26894). Changes are saved separately in
`patches/md-mm-interpreter-session.patch`; original patch is untouched.
Detailed handoff includes evidence, commands and the next DMA/mainline trace
comparison. Boot is not fixed or validated on iPad.
