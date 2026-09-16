# Machinedrum interpreter handoff — 2026-09-16, latest session

**Boot is NOT fixed.** User requested stopping for quota handoff. This file
supersedes conflicting conclusions in MD_MM_IOS.md. No commits or device tests.

## Working checkout and saved changes

Actual surviving scratch checkout (provided by user):

```
/private/tmp/claude-501/-Volumes-ExtFS-charlesvestal-github-schwung-parent-gearmulator-ios/571c5226-b835-41c3-b4e2-855d1821bc2f/scratchpad/mdmm
```

It has build-interp and build-jit, both updated, plus prior iOS/diagnostic builds.
Firmware: `/tmp/mdrom/elektron_sps1-1uw_os1.63.bin`.
No session builds/tests remain running at handoff.

Original `patches/md-mm-ios.patch` is untouched. New changes are preserved in
`patches/md-mm-interpreter-session.patch`, an incremental patch applied at the
fork root AFTER the original patch. Contains one verified correction and
TEMPORARY diagnostics, not a boot fix. Its `git apply --check` passed against
`/tmp/md-debug`, a fresh alpha.12 clone with the original patch applied.

The original patch concatenates parent and DSP-submodule diffs. Split at
`### --- submodule source/dsp56300 ---`, apply first part in parent and second
in source/dsp56300, excluding the dirty asmjit gitlink. It omits the actual
asmjit virtmem.cpp change and the untracked mdBench.cpp/iosmain.mm that its
CMake references. All exist in the surviving scratch checkout. Fresh builds
need those recovered or the unused bench target omitted. `/tmp/md-debug` has
no usable build. The sibling ../gearmulator-md-mm is an older reorganized HEAD.

Selected evidence is copied into `docs/md-interpreter-evidence/` so it survives
/tmp cleanup. Full logs/traces remain at the /tmp paths below.

## Confirmed corrections to previous handoff

### Clock clamp actually defaults ON

In BOTH scratch source and saved patch, `Dsp::writeWordToDsp` reads
MD_HDI08_SLACK but defaults to 2048 and applies that ceiling whenever a machine
clock deadline exists. The earlier claim that this experiment defaults OFF
was false. We did not change this source default.

All unclamped comparisons this session explicitly used:

```
MD_HDI08_SLACK=1000000000
```

This makes the experimental ceiling ineffective for these short tests while
retaining the original inline 100k-cycle drain limit. Always set it next.

### Requested write trap: audio samples, not established code corruption

Instrumented `Memory::dspWrite` AFTER `memTranslateAddress`. It identifies:

```
P:00042d 566200  move a,x:(r2)
P:00042e 576300  move b,x:(r3)
```

These follow a 16-iteration loop loading r2/r3 from X:$c0 onward and samples
from Y memory. MD explicitly bridges external X/Y into P above 0x020000.
Therefore external audio sample writes legitimately appear in P snapshots.
There is no evidence that this region was executed as code or that the upload
ran past its end. The original causal inference was wrong.

Default-clamp trace (`/tmp/md-trap-interp.log`): producer first writes its
expected word at 14ff1d; mixer clears the address at 143e68, then writes zero
through 42d. At ~277695159 cycles mixer 42e writes 0x57; at ~277695164 mixer
42d writes 0xaf. Tick30 has 424 words, panel3380. Full mixer disassembly in
`/tmp/md-trap-rom.log`; filtered copy preserved in docs evidence.

Trap's pc field is computed as getPC()-1, not a true current-PC accessor.
The identified stores are one-word instructions, making these PCs valid.
The trap remains in source; its one-time disassembly range was subsequently
changed to loader 14ff00..14ff3f rather than mixer 0..9ff.

### With clamp disabled, the 222-word divergence disappears

Before the new accounting correction, same-tick unclamped controls:

- JIT tick30: 202 nonzero mixer P words.
- Interpreter tick30: 202 words, panel3160, still failing.
- JIT full readiness test PASSES: fresh26894 bytes; repeat22090 bytes.
- Mixer hash 4e11815db4f755e5, 202 words.
- Producer hash 1e7a88cba19ce116, 125648 words.

Logs `/tmp/md-control-jit.log`, `/tmp/md-control-interp.log`.
Thus the 222 extra words belong to the clamp experiment, not the unclamped
interpreter boot failure. Do not resume the upload-overrun theory.

### Verified new correction: bounded DO charged twice

`do_exec` already charges cycles/instructions. Bounded return leaves
pcCurrentInstruction unchanged, so `execOp` then charges DO AGAIN.
Existing test `testCycleAccounting` FAILED at interpreterunittests.cpp:157
(`dsp.getCycles() == 5`) before correction.

Applied in dsp.cpp::execOp:

```cpp
const TWord currentOp = pcCurrentInstruction;
const auto instructionsBefore = m_instructions;
// ... existing exec_jump ...
if(pcCurrentInstruction == currentOp && m_instructions == instructionsBefore)
{
    // existing instruction/cycle accounting
}
```

This retains accounting IN do_exec and prevents duplicate outer accounting.
Forced-interpreter dsp56kTestRunner then PASSED, exit0.
Logs `/tmp/md-unit-before.log`, `/tmp/md-unit-account.log`.
The existing regression already reproduced it; no new test was added.
Full 18-second firmware test STILL FAILS at3160, with both hashes equal to JIT.
Log `/tmp/md-account-interp.log`. Keep this fix; it does not establish boot.

## Current investigation

### Exact initial loader state matched between engines

Added traceDivergence() to JIT block entry in DSP::execJitImpl. For JIT trace,
set `GEARMULATOR_MDMM_BOUNDED_JIT=0`, because generated execUntilCycles bypasses
that C++ hook. This is diagnostic routing, not a scheduler fix.
Interpreter traces are per instruction; JIT traces are per BLOCK. Align PCs
and loop counts, never simply compare line positions. Trace now prints cycles,
instruction counter, A/B/X/Y, and R0..R7 after each original header record.

With PC trigger14ff1b, both producer engines start with EXACT same state:

```
PC=14ff1b LC=24 LA=14ff20 SR=8019 SC=2
cycles=103333516 instr=20666638 r0=0
```

First word consumed identically. On second word at PC14ff1d, LC23, registers
still equal, JIT cycles103333531/instr20666644; interpreter
cycles103333666/instr20666671. Interpreter performed 27 extra five-cycle
BRCLR polls before next host word arrived.

Hypothesis, NOT complete root cause: interpreter DSP::exec() continues across
loop-back and polls within its 32-instruction bounded slice, whereas JIT yields
at a block boundary and host posts next word sooner. This accumulates loader
delay. Mixer reaches100000 with equal printed regs but different times:
JIT cycles118459123/instr23747988; interpreter145822133/instr29220590.

Diagnostic `MD_MAX_DO_ITERATIONS=1` moves interpreter upload before tick12,
but STILL FAILS3160. No source change for this knob. Log
`/tmp/md-slice1-interp.log`. Do not present changing slice size as the fix.

Full producer traces: `/tmp/md-loader-int/dsp1.trace` and
`/tmp/md-loader-jit/dsp1.trace` (10000 records). First100 lines preserved in docs.
Loader disassembly in `/tmp/md-loader-int.log` and preserved filtered copy.

Caution: JIT intermediate X/Y/SR snapshots may differ due to deferred flags or
dead-store elimination. At100019 A/pointers matched but Y/SR differed. This
alone is NOT an established arithmetic bug, and no change was based on it.

### Next useful comparison: DMA0 handler versus mainline completion

P:9da is an explicit ERROR infinite loop, not a healthy panel-driving region:

```
18:  jsset #0,x:<<$fffff4,9c2    ; DMA channel0 vector
9c2: save accumulator
9c8: movep #$c861c0,x:<<$ffffec
9ca: move x:>$647,a
9cc: add #1,a
9cd: cmp #3,a
9ce: bge 9d8
9cf: move a,x:>$647
... restore accumulator; rti
9d8: movep #0,x:<<$ffffe8
9da: jmp 9da
...
9a5: move #0,x0
9a6: move x0,x:>$647
9a8: bra 3c
```

Three DMA0 handler visits without mainline resetting647 can land at9da.
Why that happens remains unproven. Do not attribute it to the sample table.

Latest trace option `DSP_TRACE_EVENTS=1` filters to PCs44,49,9c2,9a8,100000.
These are render dispatch, DMA handler, render completion and initialization.
Use DSP_TRACE_COUNT=500. Interpreter event capture finished, exit1; its JIT
counterpart HAS NOT BEEN RUN. Run that next with identical environment.

Interpreter: `/tmp/md-events-int/dsp0.trace`, also preserved in docs evidence.
First mainline9a8 cycle146772419; dispatch49 at146837767; DMA9c2 at146838899;
mainline9a8 at146895099. Many later records exist; compare JIT before concluding.
Final interpreter event run accidentally overlapped last seconds of JIT build;
DO NOT use elapsed time for performance. No throughput claims were made.

## Commands and hygiene

```sh
cd /private/tmp/claude-501/-Volumes-ExtFS-charlesvestal-github-schwung-parent-gearmulator-ios/571c5226-b835-41c3-b4e2-855d1821bc2f/scratchpad/mdmm
cmake --build build-interp --target mdPanelReadinessFirmwareTest dsp56kTestRunner -j 4 > /tmp/md-build-next.log 2>&1
# WAIT for build to finish.
build-interp/source/dsp56300/source/dsp56kTestRunner/dsp56kTestRunner > /tmp/md-unit-next.log 2>&1
GEARMULATOR_MD_FIRMWARE_BIN=/tmp/mdrom/elektron_sps1-1uw_os1.63.bin \
 MD_TEST_SECONDS=18 MD_SNAP_TICK=30 MD_HDI08_SLACK=1000000000 \
 build-interp/source/elektron/md/mdLibTest/mdPanelReadinessFirmwareTest > /tmp/md-next.log 2>&1
```

Next JIT event comparison (binary already rebuilt; no build running):

```sh
mkdir -p /tmp/md-events-jit
GEARMULATOR_MD_FIRMWARE_BIN=/tmp/mdrom/elektron_sps1-1uw_os1.63.bin \
 MD_TEST_SECONDS=3 MD_HDI08_SLACK=1000000000 \
 GEARMULATOR_MDMM_BOUNDED_JIT=0 DSP_TRACE_DIR=/tmp/md-events-jit \
 DSP_TRACE_EVENTS=1 DSP_TRACE_COUNT=500 \
 build-jit/source/elektron/md/mdLibTest/mdPanelReadinessFirmwareTest > /tmp/md-events-jit.log 2>&1
```

A 2/3-second run intentionally fails readiness assertions; it captures traces.
Normal verdict uses18 seconds. Existing logs contain NULs: use rg -a on saved
files. Never pipe running tests through grep. No builds/tests concurrently.

Keep prior exclusions: no threads, no repeating DO epilogue-condition or scalar
stack-guard experiments, no ESSI time-base retest. Preserve do_exec accounting,
rate-limited LOG_ERR_BASE, macOS-only mach_vm and asmjit iOS header fixes.
Keep clamp explicitly disabled. Distinguish equal-tick comparisons from equal
instruction-boundary comparisons. Current code contains legacy experimental
changes and misleading comments; do not mistake them for verified fixes.

---

# Session 3 — 2026-09-16, continued

**Boot still NOT fixed.** This section supersedes earlier conflicting text.

## Everything now lives on durable storage

The /tmp scratch checkout is gone as a working location. Authoritative tree:

```
/Volumes/ExtFS/charlesvestal/github/schwung-parent/md-interp-work/
  mdmm/                  source + build-interp + build-jit (reconfigured here)
  artifacts/             every former /tmp/md-* log and trace, plus mdrom/ (both ROMs)
  logs/ traces/          this session's output
  reference-binaries/    the pre-move binaries, for byte-comparison
```

The old scratch path was renamed to `mdmm.STALE-USE-md-interp-work` so any stale
command fails loudly instead of silently editing an orphaned copy.

Both builds were reconfigured and rebuilt from scratch in the new location
(CMake bakes absolute paths; the ninja dep database cannot be safely relocated
by search-and-replace). The move is verified faithful: the durable tree
reproduces the baselines exactly — unit suite exit 0, JIT fresh 26894 /
repeat 22090 PASS, interpreter 3160 FAIL with mixerPC=0x9da, producerPC=0xbb,
and binaries byte-identical in size to the stashed references.

## The frame-sync fast-forward is NOT the cause (disproved)

`skipToFrameSync()` / `DSP::fastForward()` exists only in `jitops_jmp.cpp`, is
JIT-only, and advances the DSP instruction AND cycle counters — so it changes
emulated timing, not just speed. That made it the leading suspect.

Added env gate `MD_NO_FRAMESYNC_FF=1` (in `skipToFrameSync`, jitops_jmp.cpp) to
disable it. Control result: the JIT with the fast-forward disabled still PASSES,
with byte-identical output and identical cycle counts to the digit (26894 /
22090, mixerCycles=1828788171). The path is never taken during MD boot.
Do not revisit this.

## New diagnostic: PC histogram

`DSP_PC_HIST=<dir>` (dsp.cpp) counts executions per PC into a flat 0x200000
array and dumps the top 200 PCs per DSP at exit. Interpreter counts are
per instruction; JIT counts are per BLOCK ENTRY — a JIT self-spin loops inside
generated code without re-entering the hook, so JIT counts UNDERSTATE spins.
Never compare the two counts directly as if they were the same unit.

Interpreter, 18s run: mixer 77.31% at 0x9da (the error hang — a consequence,
not a cause); producer 83% across the 4-instruction ISR spin 0xbb–0xbf.

## The divergence is exactly tick 11, in the producer, and it is CYCLE COST

`MD_EARLY` per-tick lines from both engines (logs/early-jit.txt, early-interp.txt):

- Ticks 1–10: **bit-identical** in both engines, instruction counts AND cycle
  counts matching to the digit. The emulation is fully deterministic to here.
- Tick 11 — first divergence, in the producer, still in the bootstrap loader:

```
JIT  producerPC=14ff1e producerInstr=22896960 producerCycles=111619883
INT  producerPC=14ff1b producerInstr=22534957 producerCycles=111800636
```

The interpreter executed 362,003 FEWER instructions while charging MORE cycles.
Over the tick 10 -> 11 window: JIT 2,578,590 instr in 10,027,682 cycles =
3.888 cycles/instr; interpreter 2,216,587 instr in 10,208,435 cycles =
4.605 cycles/instr. About 18% more expensive per instruction.

The mixer is still identical at tick 11; the producer diverges first, and only
once it enters the bootstrap DO loop at 14ff1b.

## Ruled out this session (do not retry)

- **Scheduler granularity.** `MD_MAX_INSTR_PER_BLOCK` = 1, 2, 4, 8, 16 ALL fail
  identically at 3160 bytes / mixerPC=0x9da. Even a 1-instruction slice, the
  finest possible scheduler resolution, does not help. The "27 extra host-port
  polls" is a symptom of the cycle-cost gap, not a cause. The slice-invariance
  the code asserts in mddsp.cpp does now hold.
- **Bounded DO.** `MD_MAX_DO_ITERATIONS` 4 vs 64 gives IDENTICAL tick-11
  numbers. `MD_MAX_DO_ITERATIONS=0` (unbounded) DEADLOCKS — the DSP never
  yields so the host can never post the next word. Do not use 0.
- **Frame-sync fast-forward** (above).

## Next step

Both engines call the same shared `dsp56k::calcCycles()` with the same
arguments — interpreter at `dsp.cpp:1553`, JIT at `jitblock.cpp:195` — so the
per-opcode table is NOT the difference. The difference is WHEN and HOW OFTEN
each charges:

- interpreter: per instruction, at execution time (`getOpcodeCycles`, dsp.cpp:708/790)
- JIT: summed over a whole block at COMPILE time, charged per block execution

Leading hypothesis, NOT yet established: a JIT block containing a branch-to-self
spin charges its encoded cycle count once per block ENTRY rather than once per
spin ITERATION, so the JIT undercharges spin loops. That would make the JIT's
DSP effectively faster than real time during the host-port handshake, which is
what lets the upload finish before the mixer's DMA deadline.

If that is confirmed, the interpreter is the ACCURATE engine and the JIT is
optimistic — meaning the real defect is elsewhere (the MCU rate or the ESSI
clock being too slow relative to the DSPs), and matching the JIT's undercharge
would be a bug-compatible workaround, not a fix. Establish which engine is
right before changing either.

To verify: instrument cycles charged per PC over a fixed window at 14ff1b–14ff21
in both engines and compare per-iteration cost of the host-poll spin.

## Session 3, part 2 — two separate bugs, the first one solved

### Bug 1 (SOLVED): the HDI08 drain overshot by a whole slice

Instrumented `Dsp::writeWordToDsp` to measure what one host word actually costs
(`MD_HOSTWORDS ... drainCyclesPerWord= drainExecsPerWord=`). Result:

```
interpreter (slice 32):  145 cycles/word, 1.0 exec calls
JIT:                     5.4 cycles/word, 1.1-1.6 exec calls
```

Both use ~1 exec() per word, but ONE interpreter exec() charged ~145 cycles.
No DSP56300 instruction costs that: 145 / ~4.5 cycles-per-instruction = 32 =
exactly `maxInstructionsPerBlock`. The interpreter's exec() ran a full
32-instruction slice and overshot; the JIT stopped at the small loader poll
block. The ratio 145/5.4 ~= 27 is the same "27 extra polls" seen earlier.

`MD_MAX_INSTR_PER_BLOCK` DOES affect the interpreter (an earlier note implying
otherwise was wrong). At slice 4 or 1 the cost drops to 5.4/4.9 — matching the
JIT — and the upload then tracks the JIT tick for tick: 192,000 words at tick 11
(JIT 191,000), and at tick 12 mixer 18,000 / producer 250,000, identical to the
JIT, with the mixer running its own program instead of parked in the loader.

The upload throttle is therefore eliminated. This did NOT make MD boot, because
there is a second, independent failure.

Correction to an earlier claim in this file: the slice sweep "ruling out
scheduler granularity" was measuring the wrong thing. Slice size matters a great
deal to the drain cost; it just does not fix the second bug.

### Bug 2 (OPEN): the mixer takes three DMA0 interrupts without completing

Event trace of the failing interpreter run ends with three consecutive `0009c2`
and no `0009a8` between them — literally the fatal condition (fault counter at
x:$647 reaches 3 -> 9d8 -> 9da). Elsewhere in the run a double `9c2 9c2` occurs
and survives, because a `9a8` resets the counter.

Ruled out as the cause of bug 2:

- **DMA/ESSI rate.** DMA0 period is IDENTICAL in both engines: median 147,456
  cycles (JIT 147,449, mean 147,456 in both). The EssiClock is not running fast
  in the interpreter. Mainline period 73,737, i.e. two completions per DMA
  period when healthy.
- **Lost Port C handshake edges.** The producer spins at 0xbb-0xbf polling bit 1
  of x:$FFFFBD (ESSI_PDRC, Port C GPIO), waiting for a mixer->producer block
  sync. mdhardware.cpp defers that edge and can DISCARD an unreleased one, which
  looked like a lost-wakeup race. Instrumented it (`MD_PORTC deferred/released/
  discarded`): **discarded = 0 in both engines**, deferred always equals
  released. The handshake works.

What the Port C counters DO show is where the run goes wrong, precisely:

```
tick  18..23   JIT and INT identical  (862, 998, 1138, 1274, 1410, 1550)
tick  24       JIT 1686   INT 1928     <-- INT emits 378 edges in one tick
tick  25       JIT 1826   INT 1928         against a steady ~136-140/tick
tick  26       JIT 1962   INT 2110     <-- mixer enters 9da
```

The two engines are bit-identical through tick 23. At tick 24 the interpreter's
mixer emits a BURST of ~378 block-sync edges, about 2.8x the steady rate, while
sitting at PC 42 (the healthy render dispatch, same as the JIT). Two ticks later
it faults. The burst is the anomaly to chase, not the 9da hang, which is the
consequence.

Note the producer's poll loop at 0xbb is a 5-instruction loop ending in `beq`,
NOT a jump-to-self, so the JIT's spin-loop detector never matched it either.

### Next step

Trace the mixer across ticks 23-26 with cycle stamps and find what produces the
tick-24 burst of Port C writes. Correlate against DMA0 (9c2) and mainline (9a8)
events in the same cycle window, and against the mixer's DMA4 enable state,
since the edge release is gated on DMA4 being enabled.

### Diagnostics added (all env-gated / off by default)

- `DSP_PC_HIST=<dir>` — per-PC execution histogram, dumped at exit (dsp.cpp).
- `MD_NO_FRAMESYNC_FF=1` — disable the JIT frame-sync fast-forward (jitops_jmp.cpp).
- `MD_SPIN_FREE=1` — do not charge cycles for an idle self-spin. **LIVELOCKS**
  (the scheduler's `while(cycles < deadline)` never exits). Kept only as a
  documented dead end; do not enable.
- `MD_DISASM="dsp,startHex,endHex,tick"` — disassemble a P-memory range once
  (panelReadinessFirmwareTest).
- `MD_HOSTWORDS` now reports per-word drain cost; `MD_PORTC` reports handshake
  edge accounting.

`MD_MAX_DO_ITERATIONS` large values DEADLOCK (0 and 64 both hang), same as
unbounded. Do not raise it.

## Session 3, part 3 — ROOT CAUSE of bug 2, and a warning about these instructions

### WARNING: `MD_HDI08_SLACK=1000000000` disables the fix, not an experiment

The previous handoff instructs "Always set MD_HDI08_SLACK=1000000000 next" for
every comparison. That value DISABLES the clamp in `Dsp::writeWordToDsp` that
exists specifically to bound the inline drain. Every measurement taken under
that flag has the mitigation switched off. Baselines for reference:

```
interpreter, MD_HDI08_SLACK=1e9 (handoff's setting):  3160 bytes
interpreter, NO env overrides at all (true default):  3380 bytes
JIT:                                                 26894 bytes (passes)
```

Quote the flag you used with every number. Do not treat 3160 as "the"
interpreter baseline; the true default is 3380.

### Root cause of bug 2: the inline HDI08 drain, measured

Instrumented the drain (`MD_DRAIN mixTotal/mixMax`, `MD_STUCKDRAIN`).

Per-tick mixer cycle advance, interpreter vs JIT:

```
JIT  ticks 19-31:  10.03M / 10.32M alternating, perfectly steady
INT  ticks 19-23:  identical to the JIT
INT  tick 24:      27,833,223      tick 25: 0
INT  tick 26:      29,219,885      ticks 27,28: 0, 0
INT  tick 29:       3,993,678      tick 30+: back to steady
```

Ticks 24-29 total 61.04M = 10.17M/tick, EXACTLY the steady average. The
scheduler delivers the right total in LUMPS, starving the mixer for whole ticks,
so queued DMA0 requests fire back to back on resume — the three consecutive
`9c2` with no `9a8` that is the fault condition.

The lump is the drain. At tick 24, 26.0M of the mixer's 27.83M cycles are inline
drain, with single calls hitting `mixMax=100,007` — the hard 100k inline limit —
about 260 times in one tick. The JIT at the same tick: `mixMax=120`, total
growing smoothly at ~200k/tick.

`MD_STUCKDRAIN` says why the drain never completes:

```
MD_STUCKDRAIN dsp0 cycles=100000 pc=000253 sr=0000d4 rxData=1 rxIrqEn=0 pendingIrq=0
MD_STUCKDRAIN dsp0 cycles=100000 pc=00003f  sr=0000d8 rxData=1 rxIrqEn=0 pendingIrq=0
... (pc scattered: 253, 3f, 251, 3ee, 22e, 68e, 97d, 20d, 211)
```

**`rxIrqEn=0` and `pendingIrq=0` in every case.** The HDI08 holds data but the
mixer's receive interrupt is DISABLED, so no interrupt will ever deliver it. The
mixer reads it only when its own code polls, and the scattered PCs show it is
running normal work nowhere near that poll. Spinning 100,000 cycles waiting for
`hasRXData()` to clear is therefore futile by construction.

This is confirmation, by independent measurement, of the analysis already
written in the comment above the clamp in mddsp.cpp ("550 clamp hits on the
mixer, ~55M cycles ... drift that desynchronises the ESSI link").

### Why neither clamp setting works

```
slice 4 + slack 1e9      -> 3160, lumps of 100k/word
slice 4 + slack 100000   -> 3160
slice 4 + slack 10000    -> HANGS
slice 4 + slack 2048     -> HANGS
slice 32 + slack 2048    -> 3380 (true default)
```

Unclamped it lumps and desynchronises the ESSI link; clamped tightly it
deadlocks, because once the MCU declines to advance the DSP, NOTHING else
advances it either — `schedCatchUpDsp` sees the DSP already at its machine-clock
deadline and declines too, so the pending word never drains.

### The actual design defect, and the fix direction

mdLib is the only synth in this tree without a DSP thread. xtLib's
`DSP::hdiTransferUCtoDSP` does NOT advance the DSP inline at all — it posts the
word and lets the DSP's own thread consume it, with the MCU waiting via
`ucYieldLoop`. mdLib has no such yield path (grep: only `std::this_thread::yield`
on the threaded paths), so it substitutes "run this one DSP far into the future
from the MCU's thread", which is what produces the lumps.

Threading is excluded here (already disproved). The fix is a single-threaded
equivalent of `ucYieldLoop`: when the MCU needs HDI08 room, advance the WHOLE
machine in small bounded steps through the normal scheduler — all components in
lockstep — instead of running one DSP in isolation past the shared clock. That
removes the lump (fine-grained interleave) and the deadlock (something always
advances the DSP) at the same time.

Test the fix against the true default baseline (3380) and the JIT (26894), and
re-run the dsp56kTestRunner unit suite, which must stay at exit 0.

## Session 3, part 4 — the UC->DSP stream silently loses words

Instrumented the post itself: `writeRX` called while `hasRXData()` is still true
overwrites a 1-deep HRX, i.e. a host word is lost. Counted as `mixLost/prodLost`
in the `MD_DRAIN` line. Four-second runs:

```
                            mixMax    mixLost  prodLost
interpreter, slack 1e9      100,048       539        57
interpreter, slack 2048       2,102     6,275       889
JIT,         slack 1e9          120         0         0
JIT,         slack 2048         120        22       269
```

Two things follow.

1. **The JIT loses nothing when unclamped.** Every word drains in <=120 cycles.
   The interpreter's data loss is a CONSEQUENCE of its drain failing to
   complete: the drain hits the 100k cap, returns anyway, and the post then
   overwrites an unconsumed word.
2. **The clamp trades lumps for data loss.** Tightening slack from 1e9 to 2048
   cuts the worst lump 50x (100,048 -> 2,102) but loses 11x more words
   (539 -> 6,275). It induces loss in the JIT too (0 -> 22/269). Neither knob
   has a good setting; this is a design defect, not a tuning problem.

### Correction: rxIrqEn=0 is normal, not the differentiator

Part 3 read `rxIrqEn=0` as "no interrupt will ever deliver the word". Measuring
the JIT at the same points shows `rxIrqEn=0` there as well — this firmware polls
the HDI08 in software rather than using the receive interrupt. So that flag does
not distinguish the engines. The open question is narrower and unchanged:

**Why does the interpreter's mixer sometimes need >100,000 cycles to reach its
HDI08 polling code, when the JIT's reaches it within 120?**

Both engines are bit-identical up to tick 23 and the divergence begins with the
first mixer-bound host traffic at tick 24, so the window is small and exactly
reproducible.

### Fix direction (unchanged, now better evidenced)

Never overwrite an unconsumed HRX, and never run one DSP far past the shared
clock. Both require what mdLib lacks and xtLib has: a way for the UC to WAIT in
machine time. The single-threaded equivalent is to advance the whole machine in
small steps through the normal scheduler while the UC is blocked, rather than
running the target DSP in isolation from inside the UC's own execution.
Reentrancy is the reason the current code does it the wrong way round:
`writeWordToDsp` is called from `hdiTransferUCtoDSP`, which is itself inside
`advance() -> schedStep() -> processUC()`.

Validate any fix against: true default baseline 3380 bytes, JIT 26894, unit
suite exit 0, AND `mixLost`/`prodLost` both 0.

## Session 3, part 5 — bug 1 fixed in code; bug 2 traced to the host-receive DMA

### Bug 1 now has a real fix (gated): `execMinimalStep()`

`DSP::exec()` deliberately runs up to `maxInstructionsPerBlock` instructions "to
match the JIT's granularity". That premise is wrong for a caller that must stop
the instant a condition flips: a JIT block ends at real control flow, and the
bootstrap loader's poll loop compiles to a handful of instructions, not 32. The
HDI08 drain therefore overshot by a whole slice per host word.

Added `DSP::execMinimalStep()` (dsp.h) — execJit() under the JIT, one
`execInterpreter()` otherwise — and used it in the drain under
**`MD_DRAIN_MINSTEP=1`**. Measured at the DEFAULT slice, no other overrides:

```
per host word:  145 cycles  ->  6.5-8.1     (JIT: 5.4)
tick 11 producerPC:  14ff1b ->  14ff1e      (JIT: 14ff1e — now matching)
tick 11 instr gap:  -362,003 ->  +28,455
```

It is NOT on by default: with the inline clamp active it deadlocks at tick 25,
because a drain that gives up early leaves the word unconsumed and nothing else
advances that DSP — the same failure the clamp comment already describes.
Default behaviour is unchanged and verified (3380 bytes, unit suite exit 0).
Turning this on for real requires reworking the clamp, which is the next job.

### Bug 2: the mixer never arms its host-receive DMA channel

Decoded the mixer's DMA channels properly (`DRS = (DCR >> 11) & 0x1f`; for the
DSP56303 `Hi08ReceiveDataFull = 0b10011`, NOT the 56362's 0b10000):

```
ch0 c861c0 DE=1 Essi1Rx     ch1 d06510 DE=1 Essi1Rx
ch2 8e5a50 DE=1 Essi0Tx     ch3 000000 DE=0 IRQA
ch4 8e52c4 DE=1 Essi0Rx     ch5 0e9ac4 DE=0 Hi08ReceiveDataFull  <-- DISARMED
```

Channel 5 is the host-receive channel and its DE bit is clear, so no DMA moves
the word and the drain waits for the core to poll. Counting the arm state at
every host post to the mixer, same phase in both engines:

```
                 mixDmaArmed   mixDmaDisarmed   mixLost
JIT   tick 24         9,024            2,005          0
JIT   total         164,981           36,861          0
INT   total               0              540        539
```

**The interpreter never arms it. Not once.** The JIT arms it 82% of the time,
from the first tick of mixer host traffic, and loses nothing. Every interpreter
post lands on a disarmed channel and almost every one loses its word.

Important caveat, do not skip it: the mixer is still ALIVE when this happens
(PCs 4c4, 4c9, 4cb, 4ce, 4d0, 5ab at ticks 24-28; it only reaches 9da at tick
29), but its PCs differ from the JIT's (3c-43) well before, so the arming
failure is DOWNSTREAM of the earlier divergence, not yet proven to be the first
cause.

Also corrected: `m_waitServeRXInterrupt` is NOT latched here (measured
`waitServeRx=0`, `arb=1`, `dmaTrig=1`), so `HDI08::exec()` retries the DMA
trigger every call. The trigger fires; the channel is simply disabled.

### Next step

Find where the mixer firmware writes DCR5 with DE set, and why the interpreter
never executes it. `MD_DISASM="0,startHex,endHex,tick"` disassembles a range.
The write is a `movep` to x:$FFFFF5 (DCR5) — the same form as the `movep
#$c861c0,x:<<$ffffec` already seen in the DMA0 handler. Trap writes to the DMA
control registers in both engines and compare.

### Diagnostics added in this part

- `DSP::execMinimalStep()` + `MD_DRAIN_MINSTEP=1` (off by default).
- `MD_DRAIN` now also reports `mixLost/prodLost` and `mixDmaArmed/mixDmaDisarmed`.
- `MD_STUCKDRAIN` / `MD_STUCKPC` / `MD_STUCKDMA` with `MD_STUCK_THRESHOLD`,
  reporting PC histogram, HSR, arbitration, DMA trigger and all six DCRs.
- `HDI08::diagWaitServeRx()` / `diagHasDmaReceiveTrigger()`.

## Session 3, part 6 — the host-receive ISR chain, and the HRX depth model

### Correction: BOTH engines arm the host-receive channel

Part 5 said the interpreter "never arms" DMA channel 5. That was measured at
POST time only. Tracing every DCR write (`DSP_DCR_TRACE=1`, dma.cpp) shows both
engines arming it, from the same routine. The difference is RATE:

```
arming writes (DE 0->1, DRS=0x13), 4 second run:
  JIT          17,908     interval ~236 - 12,800 cycles
  interpreter      44     interval ~1,900,000 - 2,200,000 cycles
```

Channel 5 is a clear-DE one-shot: it fires, DE clears, the ISR re-arms it. So
"disarmed at every post" is the symptom of a stalled re-arm chain, not of the
firmware never arming it.

### The re-arm chain, disassembled

```
9aa: movep x:<<$ffffc6,x:<<$ffffda   ; read HRX into the DMA5 registers
9ac: movep #>$0e9ac4,x:<<$ffffd8     ; DCR5 = DE 0  (disarm)
9af: brclr #$0,x:<<$ffffc3,*         ; SPIN until HSR bit0 (HRDF) - next host word
9b1: movep x:<<$ffffc6,x:<<$ffffd9   ; read that word
9b3: movep #>$8e9ac4,x:<<$ffffd8     ; DCR5 = DE 1  (re-arm)
9b5: rti
```

It is an ISR that blocks waiting for the next host word before re-arming. While
it spins there the mixer's mainline cannot run, so DMA0 keeps incrementing
x:$647 with nothing to reset it. The chain is self-sustaining only while host
words keep arriving: a DMA5 completion raises the interrupt that re-arms DMA5.

Exact execution counts on the mixer (PC histogram; note the dump was capped at
the top 200 PCs, which earlier hid these — the cap is now 4000):

```
            9aa/9b1 (ISR entries)    9af (the spin)    9c2 (DMA0 audio)
JIT                  15,204                19,683       normal
interpreter              28                    28        1,053
```

The interpreter's host-receive ISR runs **28 times against the JIT's 15,204**,
and does not spin when it runs. Audio DMA0 keeps going. So the host-word path
to the mixer stops almost immediately while the rest of the machine continues,
and because the re-arm lives inside the ISR that only a completed transfer can
trigger, it cannot restart once broken.

### Structural root: HRX is modelled as an 8192-word FIFO

```cpp
RingBuffer<TWord, 8192, true> m_dataRX;   // hdi08.h
void HDI08::writeRX(...) { m_dataRX.waitNotFull(); m_dataRX.push_back(d); }
```

A real DSP56303 HI08 has a ONE-WORD HRX plus a host-side latch. mdLib knows
this — writeWordToDsp's own comment says "a host latch and a one-word HRX" — and
the entire inline drain exists to fake 1-deep semantics on top of a 8192-deep
FIFO. Two consequences, both observed:

- HRDF stays asserted while ANY queued word exists, so the firmware's 1-deep
  handshake at 9af/9b3 does not see the edges it expects.
- `waitNotFull()` BLOCKS. That is the mechanism behind every "HANG" in this
  file, including the clamp deadlocks and `MD_DRAIN_MINSTEP` at tick 25.

This is shared code, so it does not by itself explain JIT vs interpreter; it
explains why mdLib needs the drain at all, and why every attempt to bound the
drain either lumps or deadlocks. The engines differ in timing on top of it, and
the interpreter falls off the cliff.

### Recommended next move

Give MD true 1-deep receive semantics instead of compensating for the FIFO:
post a word only when HRX is genuinely empty, and make the UC wait in machine
time when it is not (the single-threaded `ucYieldLoop` equivalent). That
addresses the lumps, the data loss and the deadlocks together, rather than
trading them against each other. Until then no clamp setting can work: the
measurements in parts 3-5 show the trade is forced.

## Session 3, part 7 — the flow-control flags are modelled, HREQ is not

### Correction: "data loss" was over-counted, but it is still real

Parts 4-5 counted a post as lost whenever HRX was non-empty. That is wrong: the
real HI08 has a host latch in FRONT of the one-word HRX, so two words in flight
is legal, and mdLib models exactly that (mddsp.cpp, hdiUcReadIsr):

```
horxDepth == 0  ->  TXDE | TRDY      (both clear to send)
horxDepth == 1  ->  TXDE only        (latch has room, DSP latch full)
horxDepth >= 2  ->  neither          (must wait)
```

Re-counted with depth >= 2 as the only true overflow:

```
              overflow(depth>=2)   legal depth-1 posts
JIT                          0                      0
interpreter                538                      1
```

So the loss survives the correction. The interpreter posts 538 words while BOTH
TXDE and TRDY are clear — the state in which correct firmware must wait.

### Why the UC does not wait: HREQ is unmodelled

mdLib derives TXDE/TRDY honestly from the receive depth, so the flags are right.
The gap is named in its own comment:

```
// HREQ is routed separately; composing it here would require the unmodelled IVR path.
```

The ColdFire's flow control for this transfer runs over HREQ (the host request
line), which is not modelled. Under the JIT the DSP drains fast enough that HRX
never reaches depth 2, so the missing back-pressure is never exercised. Under
the interpreter the DSP does not drain in time, depth passes 2, and with no
HREQ the UC keeps writing and words are destroyed.

This ties the whole chain together:

1. HRX is an 8192-word FIFO where the part has a 1-word HRX behind a latch.
2. The inline drain exists to fake the narrow register, and either lumps
   (100k cycles/word, ESSI desync) or deadlocks (`waitNotFull` blocks).
3. HREQ back-pressure is missing, so nothing stops the UC when the drain fails.
4. The mixer's host-receive ISR chain (disarm, wait HRDF, re-arm DMA5) starves:
   28 entries against the JIT's 15,204.
5. The mixer's mainline stops resetting x:$647, three DMA0 interrupts land
   without a completion, and the firmware jumps to its error loop at 9da.

The JIT survives all of this only because it is fast enough to never reach the
failing states. It is not more correct; it is luckier.

### Honest status

MD does NOT boot under the interpreter. Bug 1 is fixed in code but gated
(`MD_DRAIN_MINSTEP`) because the clamp deadlocks with it. Bug 2 is understood
end to end but needs real work, not a tuning knob:

- give MD true 1-deep receive semantics instead of faking them over a FIFO, and
- model HREQ back-pressure so the UC stalls in machine time when HRX is full,
  which is also the single-threaded `ucYieldLoop` equivalent mdLib lacks.

Both are changes to shared transport code and must be validated against Osirus
and the XT, which run on the same HDI08 and currently depend on its
always-ready behaviour. Baselines: interpreter true default 3380 bytes, JIT
26894, dsp56kTestRunner exit 0, and overflow counts at zero.

## Session 3, part 8 — a lossless host queue removes the fault but does not boot

Implemented `MD_HOST_BACKLOG=1` (mddsp.cpp/h, pumped from mdhardware.cpp): hold
words the DSP has no room for in an mdLib-side queue and release them as HRX
drains, instead of overwriting unconsumed words. Off by default.

Result — the fault disappears:

```
MD_HOST_BACKLOG=1:  mixLost=0  prodLost=0  mixerPC=49b  producerPC=100096
default:            mixLost=538            mixerPC=9da (error loop)
```

Both DSPs stay ALIVE. The mixer runs its own program instead of the 9da error
loop, and the producer sits in its mainline. So eliminating the data loss does
remove the DMA0 triple-fault. It still does not boot: the panel stalls at 3160.

### Why it still fails: the pump rate is a knife edge

The queue needs a release policy, and every policy tried is wrong in one
direction or the other:

```
refill HRX to depth 2       -> machine FREEZES at tick 27. TRDY is defined as
                               depth == 0, so a permanently topped-up HRX means
                               the UC never sees clear-to-send and spins forever.
refill only an empty HRX,
  pumped on catch-up only   -> runs to tick 180, no fault, but the mixer ends
                               parked at 9af waiting for HRDF: nothing refills
                               HRX while the UC is busy elsewhere.
same, pumped every
  schedStep                 -> back to 9da. Words now arrive fast enough that the
                               receive ISR thrashes and the mainline is starved
                               again.
```

Too slow and the mixer waits in its ISR; too fast and its mainline never runs.
There is no correct rate to pick from outside, because the real part does not
pick one: the DSP asserts HREQ and the UC stalls until the DSP is ready. That
back-pressure is the missing piece, and a host-side queue cannot synthesise it.

This is useful negative evidence, not a fix. It does establish one thing firmly:
**the data loss was a real and separate defect**, because removing it removes
the 9da fault outright.

### State left behind

All of it is env-gated and OFF by default. Verified after the experiment:

```
interpreter, no env overrides:   3380 bytes   (unchanged baseline)
JIT, no env overrides:          26894 / 22090  PASSES
dsp56kTestRunner:                exit 0
```

### What remains, unchanged in substance

Model HREQ back-pressure so the UC stalls in machine time when HRX is full, and
give MD true 1-deep receive semantics rather than faking them over the 8192-word
FIFO. Both touch shared HDI08 code used by Osirus and the XT, which currently
rely on its always-ready behaviour, so they need their own validation. That is
the next session's work; it is a design change, not a knob.

## Session 3, part 9 — why the UC overruns, and four release policies that all fail

### Measured: the ColdFire block-writes without checking the flags

The flags are live (mc68k `Hdi08::isr()` calls the read callback on every read,
and MD sets `setForceTxde(false)` so mdLib owns TXDE/TRDY). Instrumented the
overflow directly:

```
MD_OVERFLOW dsp0 depth=2 isrReadsSinceLastWrite=0 totalIsrReads=97490
MD_OVERFLOW dsp0 depth=3 isrReadsSinceLastWrite=0 totalIsrReads=97490
...            depth=9  isrReadsSinceLastWrite=0 totalIsrReads=97490
```

The UC writes a whole block with **zero** ISR reads between words. It is not
ignoring back-pressure it can see; it never looks, because on the real machine
each word of that block is requested by the DSP asserting **HREQ**, and HREQ is
unmodelled. So correct TXDE/TRDY cannot help: nothing reads them.

This also explains why the held words are the right model — they stand in for a
block still sitting in ColdFire memory, waiting to be requested word by word.

### Four release policies, all wrong

```
refill HRX to depth 2                  -> machine FREEZES at tick 27
                                          (TRDY means depth==0; UC never sees ready)
refill only empty HRX, pump on
  schedCatchUpDsp                      -> no fault, runs to tick 180, but the
                                          mixer parks at 9af waiting for HRDF
refill only empty HRX, pump every
  schedStep                            -> 9da returns (ISR thrashes, mainline starved)
pump driven by the HRX-read event
  (setReadRxCallback)                  -> SEGFAULT at tick 24: pushing from inside
                                          the HDI08's own read re-enters it
same, deferred to a safe point via a
  request flag consumed in schedStep   -> 9da again
```

The event-driven version is semantically the right model — one word released per
word consumed, which is what HREQ does — and it still fails, because schedStep
runs often enough that "one per consume" collapses back into "as fast as the DSP
can take them". The missing constraint is not the COUNT but the TIMING: on
hardware the UC's block transfer is stretched in UC time by the wait for each
HREQ, so the UC falls behind and the mixer's mainline gets its cycles. Releasing
the words without also charging the UC for the wait reproduces the overrun.

So a correct fix has to slow the UC down, not just meter the words. That means
the UC-side stall (the single-threaded `ucYieldLoop` equivalent) is not optional
and cannot be substituted by any host-side queue policy. This is the same
conclusion parts 3-7 reached from the other direction, now with the queue built
and four policies measured.

### State: unchanged defaults, everything gated

```
interpreter, no env overrides:   3380 bytes  (unchanged)
JIT, no env overrides:          26894/22090  PASSES
dsp56kTestRunner:                exit 0
```

`MD_HOST_BACKLOG` and `MD_DRAIN_MINSTEP` are both OFF by default.

### The one genuinely new fact to build on

With the queue on, data loss goes to zero and **the 9da fault disappears
entirely** in the catch-up-pumped variant: mixer alive on its own program,
producer in its mainline, for the whole run. That is the first configuration in
this investigation where neither DSP dies. It stalls instead of faulting, which
is a strictly better failure and the right base for the UC-stall work.

## Session 3, part 10 — the UC stall works; the transport is healthy; a fifth cause remains

### The UC stall, implemented

Two halves, both under `MD_HOST_BACKLOG=1`:

1. **Hold only true overflow** (mddsp.cpp). Words go straight through at depth
   0 and 1, because latch+HRX = 2 is legal; only depth >= 2 is held. Holding at
   depth 1 throttles the bootstrap loader, which polls HRX from the core and
   consumes as fast as words arrive (measured: producer never leaves 14ff00,
   backlog 28,544).
2. **Stall the UC** (mdhardware.cpp, schedStep). While a DSP still holds
   undelivered words, advance THAT DSP in preference to the UC, so UC time stops
   exactly as it would while waiting on HREQ. If the DSP has already reached the
   shared clock it cannot advance and the UC must run, since the UC is what moves
   the clock on; refusing there deadlocks.

This is the missing half identified in part 9: metering the words is not enough,
the UC has to be charged for the wait.

### It fixes the transport, measurably

```
                        before (default)      with the stall
worst single drain        100,048 cycles        2,063 cycles
words lost                   538                    0
mixer cycles/tick     27.8M, 0, 29.2M, 0, 0   10.03M / 10.32M steady
backlog high-water              -                  241
bootstrap loader           completes            completes
```

The mixer's cycle delivery is now **indistinguishable from the JIT's** — steady
10.03M/10.32M alternating, with one small wobble (10.57M/9.77M) at the moment of
failure instead of the old 3x overrun followed by total starvation.

### And the fault is unchanged

```
... 9c2 9a8 44 9a8 49 9c2 9a8 44 9a8 49 9c2 9a8 44 9c2 9c2 9c2
```

The mixer runs a healthy pattern (DMA0, mainline completion, dispatch, repeat)
and then abruptly takes three DMA0 interrupts back to back with no completion
between them. Panel 3160, mixerPC 9da, first at tick 27.

So lumping, data loss, loader throttling and drain overshoot are ALL now
eliminated, and the firmware still faults. There is a fifth cause, and it is not
the host transport.

### The concrete lead for it

`DmaChannel::exec()` (dma.cpp) paces itself on the INSTRUCTION counter:

```cpp
const auto clock = m_peripherals.getDSP().getInstructionCounter();
const auto diff  = clock - m_lastClock;
m_pendingTransfer -= static_cast<int32_t>(diff);
```

and `IPeripherals::isDue()` likewise tests `_instructions >= m_targetClock`,
with delays that are expressed in CYCLES. Instructions and cycles are not
interchangeable (measured ~4.99 cycles/instruction here), and the two engines do
not advance the instruction counter identically — the JIT's `fastForward()` adds
to BOTH counters at once, and the JIT bills a block where the interpreter bills
each instruction. A DMA transfer delay measured in instructions is therefore
engine-dependent, which is exactly the shape of a fault that survives a
perfectly paced transport.

Next: instrument DMA0's retrigger interval in both engines, in cycles AND
instructions, across the ticks around the failure. If DMA0's own pacing differs
while the DSP's cycle budget matches, that is the fifth cause.

### State

```
interpreter, all gates OFF:   3380 bytes  (unchanged default)
JIT:                         26894/22090  PASSES
dsp56kTestRunner:             exit 0
```

## Session 3, part 11 — the fifth cause: the inter-DSP ESSI link floods

Added `MD_LINK` per-tick reporting of both ESSI0 audio input rings
(panelReadinessFirmwareTest). With the host transport already healthy (UC stall
on, cycles steady, no loss), the link tells a clear story:

```
tick     JIT mixerIn/producerIn      INTERP mixerIn/producerIn
22            0 / 5                        0 / 1
23            0 / 6                        0 / 1
24            0 / 5                        0 / 113     <-- starts to back up
25            2 / 5                        0 / 6
26            0 / 5                        0 / 1042    <-- floods
27            0 / 5                        0 / 0       <-- fault; link dead
28-30       0-1 / 5-6                      0 / 0
```

The JIT holds a steady 5-6 frames in the producer's input ring for the whole
run. The interpreter backs up to 113, then 1042, then collapses to nothing at
exactly the tick the mixer reaches 9da.

The producer's PC through that window is 0xbb/0xbd — its **Port C poll loop**,
waiting for the mixer->producer block sync (bit 1 of x:$FFFFBD). So the
sequence is:

1. the producer stalls in its Port C poll,
2. it therefore stops consuming the ESSI link,
3. the mixer keeps transmitting, so the producer's input ring floods
   (1042 frames against a healthy 5),
4. the link jams, the mixer's mainline can no longer complete,
5. three DMA0 interrupts land without a completion and the firmware jumps
   to 9da.

This supersedes the DMA-pacing guess at the end of part 10: DMA0's period was
already measured identical in both engines (147,456 cycles), and cycles per
instruction match to three decimals (4.988 vs 4.990), so DMA pacing is
inaccurate in absolute terms but NOT engine-dependent. The link is.

### Where this rejoins earlier evidence

Part 2 measured the Port C handshake and found `deferred == released`, zero
discards, and the two engines IDENTICAL through tick 23 — then the interpreter
emitting a burst of 378 edges at tick 24 against a steady 136-140. That is the
same tick the link starts backing up. The Port C rendezvous
(`m_mdOnDemandRendezvousActive`, mdhardware.cpp ~525 and ~962) gates the edge on
the mixer's DMA4 being enabled, and releases it only when the producer READS
Port C. That is the mechanism to examine next, with the link depth as the
readout.

### Next step

Instrument the Port C rendezvous and the link together across ticks 23-27:
每 edge deferred/released, the mixer's DCR4 enable state at each, the producer's
PC, and both ring depths. The question is why the producer stops being released
from its poll at tick 24, given the handshake counters were still identical at
tick 23.

## Session 3, part 12 — Port C edge queue tried and rejected

Hypothesis: the rendezvous COLLAPSES rapid transitions. It compares a new level
against a single pending level, so a 1->0->1 burst nets to no change and the
producer, which polls for a CHANGE, never sees an edge. That fits the measured
378-edge burst at tick 24.

Implemented `MD_PORTC_EDGE_QUEUE=1`: an ordered deque of transitions, one
released per producer observation, still gated on the mixer's DMA4 window.

Result: WORSE, and instructively so.

```
                       producerIn ring     producerPC     mixerPC
default                 1,1,113,6,1042,0       bb           9da
with edge queue         0,0,0,0,0,0 ...        bb           9da
```

The link never fills at all. Releasing one edge per observation drains the queue
more slowly than the mixer fills it, so the producer is released even less often
than before and parks in its poll from the start; the link then never carries
frames. Panel 3160, mixer still 9da.

So edge collapsing is NOT the mechanism, or at least fixing it in isolation
makes the release rate the binding constraint instead. Do not re-try an ordered
queue without also addressing the release gate (the DMA4 window), which is what
actually determines how often the producer is let go.

Left in the tree, OFF by default.

## Session 3 — closing state

```
interpreter, all gates OFF:   3380 bytes, mixerPC 9da   (unchanged from session start)
JIT:                         26894 / 22090  PASSES
dsp56kTestRunner:             exit 0
```

**MD does not boot under the interpreter.** What this session established, in
order of usefulness to whoever picks it up:

1. Bug 1 (drain overshoot) is FIXED in code — `execMinimalStep()`, 145 -> 6.5
   cycles per host word — gated because the clamp deadlocks with it.
2. The UC stall + overflow-only backlog makes the host transport HEALTHY:
   worst drain 100,048 -> 2,063 cycles, words lost 538 -> 0, mixer cycle
   delivery indistinguishable from the JIT's. The fault survives it.
3. The fifth and current cause is the inter-DSP ESSI link flooding (1042 frames
   against the JIT's steady 5) while the producer sits in its Port C poll.
4. Ruled out with controls: frame-sync fast-forward, scheduler granularity,
   bounded DO, ESSI/DMA rate, lost Port C edges, the RX interrupt latch,
   DMA pacing being engine-dependent, and Port C edge collapsing.
5. The JIT is not more correct anywhere here. It is fast enough never to reach
   the failing states, which is precisely why only the iPad path breaks.

The open question is narrow and reproducible: **why does the producer stop
being released from its Port C poll at tick 24**, when the handshake counters
are identical to the JIT's through tick 23? The release gate
(`m_mdOnDemandRendezvousActive` + the mixer's DMA4 enable window,
mdhardware.cpp ~525 and ~962) is the place to look, with `MD_LINK` ring depth
as the readout.

## Session 3, part 13 — the failure is a mutual wait between the two DSPs

Two final measurements close the loop.

### The Port C release gate is refused only in the interpreter

`MD_PORTC ... blockedByDma4` counts a waiting producer refused because the
mixer's DMA4 receive window was shut:

```
tick     JIT blockedByDma4     INTERP blockedByDma4
22              0                      457
24              0                      479
26              0                      567
28              0                      860  (then frozen; mixer dead)
```

The JIT is NEVER refused, across the whole run. The interpreter is refused
constantly.

### The mixer's interrupt cadence collapses at exactly tick 24

`MD_IRQ` counts injections and the pending-interrupt queue depth:

```
tick     JIT mixInject      INTERP mixInject
23            823                  626
24           1808  (+985)          699  (+73)
30           8280  (~1100/tick)   1477  (frozen)
```

`mixPendMax = 1` in BOTH, so nothing is dropped and nothing blocks on the ring's
semaphore. The mixer simply receives about thirteen times fewer interrupts.

### The deadlock

Interrupts on the mixer come from DMA completions. Putting the two measurements
together with parts 11-12:

```
the producer waits in its Port C poll (P:bb-bf)
  -> the edge is released only while the mixer's DMA4 window is open
     -> DMA4 opens when the mixer services an ESSI0 receive
        -> an ESSI0 receive requires the producer to transmit
           -> but the producer is still waiting for the Port C edge
```

It is a rendezvous that only closes if both sides keep making progress. The JIT
sustains it (~1100 mixer interrupts per tick, never refused at the gate). The
interpreter never bootstraps it: at tick 24 the cadence fails to step up, the
producer parks, the mixer's link ring floods to 1042 frames, its mainline stops
completing between DMA0 interrupts, and the third one sends it to 9da.

This is why every fix attempted so far moves the symptom without curing it. The
host transport was genuinely broken and is now genuinely fixed, and it was never
the thing keeping this rendezvous from closing.

### What this means for the fix

The rendezvous as written assumes the DSPs run fast relative to each other in a
way only the JIT delivers. Options, in the order worth trying:

1. Make the Port C release not depend on the mixer's DMA4 window being open at
   the instant the producer happens to look. The window is a clear-DE one-shot;
   gating a handshake on it is a race by construction. Releasing on "DMA4 has
   been armed at least once since this edge was deferred" would keep the
   ordering intent without requiring the two to coincide.
2. Failing that, understand what starts the cadence at tick 24 in the JIT and
   why the interpreter's equivalent never fires.

Option 1 is a small, local change to mdhardware.cpp (~962) and is testable with
the `MD_LINK` ring depth and `MD_IRQ` cadence as immediate readouts: a working
fix should show the interpreter's mixInject stepping up at tick 24 and the
producer's input ring staying near the JIT's steady 5.

## Session 3, part 14 — relaxed gate fixes the link flood; cadence is the last wall

Implemented `MD_PORTC_RELAX=1` (mdhardware.cpp): count DMA4 arming as an EDGE in
schedStep, record the count when an edge is deferred, and release when the
window is open **or has opened since** — instead of demanding it be open at the
instant the producer happens to look, which is a race against a clear-DE
one-shot.

It works, as far as it goes:

```
                       producerIn ring peak     panel bytes
default                        1042                 3380
MD_PORTC_RELAX=1                113 (then 6,7,1)    3380
```

The link no longer floods. The rendezvous is no longer the binding constraint.

The mixer still ends at 9da, because the interrupt cadence is unchanged:

```
mixInject by tick 30:   JIT 8280     interpreter 1477
```

Combining it with the host-transport work (`MD_PORTC_RELAX=1 MD_HOST_BACKLOG=1`)
is WORSE, not better: 3160 bytes and mixInject only 862. The UC stall slows the
UC, which further starves the very cadence that is already the problem. Do not
assume these compose; they interact.

### The last open question, stated precisely

Between tick 23 and 24 the JIT's mixer interrupt rate steps up roughly tenfold
(823 -> 1808 -> ~1100/tick thereafter) and the interpreter's does not
(626 -> 699 -> ~75/tick). Interrupts on the mixer are DMA completions. Nothing
is dropped or blocked (`mixPendMax = 1` in both). So the mixer's DMA channels
simply complete far fewer transfers, and the question is which channel and why.

Instrument per-channel `finishTransfer()` counts (dma.cpp) for the mixer in both
engines across ticks 22-28, split by channel index. Channels in play, decoded
earlier: ch0/ch1 Essi1Rx (codec), ch2 Essi0Tx, ch4 Essi0Rx (link), ch5
Hi08ReceiveDataFull (host). That single measurement should name the channel that
stops completing, and its request source then says whether the cause is the
codec clock, the link, or the host port.

### Closing state, session 3

```
interpreter, all gates OFF:   3380 bytes, mixerPC 9da   (unchanged)
JIT:                         26894 / 22090  PASSES
dsp56kTestRunner:             exit 0
```

Gates added this session, all OFF by default: `MD_DRAIN_MINSTEP`,
`MD_HOST_BACKLOG`, `MD_PORTC_EDGE_QUEUE` (rejected), `MD_PORTC_RELAX`.
Diagnostics: `DSP_PC_HIST`, `DSP_DCR_TRACE`, `MD_DISASM`, `MD_STUCK_THRESHOLD`,
`MD_NO_FRAMESYNC_FF`, and the `MD_DRAIN` / `MD_PORTC` / `MD_LINK` / `MD_IRQ`
per-tick reports.

## Session 3, part 15 — it is channel 5, the host-receive DMA, and nothing else

Per-channel `finishTransfer()` counts on the mixer (`MD_DMACH`), same phase in
both engines:

```
channel  source                    JIT@22  JIT@28   INT@22  INT@28
ch0      Essi1Rx (codec)              705    1119      520     911
ch1      Essi1Rx                       44      69       32      56
ch2      Essi0Tx                     1411    2239     1040    1816
ch3      unused                         0       0        0       0
ch4      Essi0Rx (inter-DSP link)    1410    2238     1039    1816
ch5      Hi08ReceiveDataFull (host)     0    4477        0     464
```

Every codec and link channel tracks the JIT to within about twenty percent — a
modest, uniform lag, not a failure. **Channel 5 is the outlier and the only
one**: the JIT has it running by tick 24 (831 completions in that tick alone,
4477 by tick 28) while the interpreter does not start until tick 26 and reaches
464, roughly a tenth.

This unifies three separate measurements taken earlier in this session, which
are all the same phenomenon seen from different angles:

```
ch5 completions            JIT 4477    interpreter 464
DMA5 arming writes         JIT 17,908  interpreter 44
host-receive ISR entries   JIT 15,204  interpreter 28
```

And it explains the cadence gap, since the mixer's interrupts are DMA
completions: the missing ~1000 interrupts per tick ARE the missing ch5
transfers.

So the whole failure reduces to one statement: **the mixer's host-receive DMA
chain never gets going under the interpreter.** The chain is self-sustaining by
construction — a ch5 completion raises the interrupt whose handler re-arms ch5
(P:9aa-9b5, disarm, wait HRDF at 9af, read, re-arm) — so it has to be started,
and once missed it cannot restart itself. Everything downstream (link flood,
Port C stall, DMA0 triple fault, 9da) follows from it.

### Why this is the right place to resume

The host transport work in parts 8-10 was aimed at the right subsystem but the
wrong property. It fixed data loss and pacing; what ch5 needs is that a host
word be PRESENT at the moment the handler arms the channel and reaches its HRDF
wait. That is a phase relationship, not a throughput one, which is consistent
with the host-transport fixes moving the symptom without curing it, and with
`MD_PORTC_RELAX` + `MD_HOST_BACKLOG` together being worse than either alone.

Resume by tracing, in both engines across ticks 23-26, the interleaving of:
the ISR at 9aa/9af/9b3, ch5's DE bit, HRX depth, and UC word posts. The question
is what the JIT has present at 9af that the interpreter does not.

## Session 3, part 16 — the chain is MCU-driven, and that is the top of the causal map

The handler that arms channel 5 is entered from vector P:0x12
(`MD_DIS 12 bf080 jsr func_0009aa`). That is not a DMA vector: on the DSP56303 a
host command's vector address is HV*2, so HV=9 lands on 0x12. The mixer's
receive chain is therefore started by a HOST COMMAND from the ColdFire, not by
anything the DSP does on its own.

Counting them (`MD_HCMD`) settles the direction of causation:

```
                  mixCmds   mixVec12    ch5 completions
JIT   @tick 24        913        831         831
JIT   @tick 28       4919       4477        4477
INT   @tick 24          0          0           0
INT   @tick 28        520        474         464
```

`mixVec12` tracks ch5 completions one-for-one in both engines. Each host command
drives exactly one channel-5 transfer. So nothing is wrong with the DSP-side
chain at all — **the MCU simply does not issue the commands**. Over six seconds:

```
JIT   16,704 commands (15,204 on vector 0x12)   panel 4204
INT      520 commands (   474 on vector 0x12)   panel 3380
```

A factor of thirty-two, with identical ucCycles at every tick. The ColdFire has
exactly the same amount of emulated time and spends it doing different work.

### Combination results, with mixVec12 as the readout

```
                                        bytes   mixCmds  mixVec12
JIT reference @6s                        4204    16,704    15,204
interpreter baseline                     3380       520       474
MD_DRAIN_MINSTEP=1 (+ clamp off)         3160        45        41
MD_PORTC_RELAX=1                         3380       520       474
both                                     3160        45        41
```

Note the bug-1 fix makes this WORSE, not better: 45 commands against the
baseline's 520. It genuinely corrects the per-word drain cost and puts the
producer on the JIT's PC at tick 11, and it still reduces the thing that
actually matters. That is a warning against treating "closer to the JIT on one
metric" as progress.

### The complete causal map, top to bottom

```
the ColdFire issues 32x fewer host commands to the mixer
  -> the handler at 9aa (vector 0x12) runs 32x less often
     -> DMA channel 5 is armed 32x less often
        -> 32x fewer host-word transfers, so 32x fewer mixer interrupts
           -> the mixer's DMA4 receive window is usually shut
              -> the producer's Port C edge is not released; it parks at 0xbb
                 -> it stops draining the ESSI link, which floods to 1042 frames
                    -> the mixer's mainline can no longer complete between DMA0
                       interrupts; the third one sends it to 9da
```

Every arrow in that chain is measured, not inferred. `MD_PORTC_RELAX` cures the
link flood (1042 -> 113) precisely because it breaks one arrow, and the boot
still fails because the arrows above it are untouched.

### Where to resume

The question is now entirely on the ColdFire side and is narrow: **what is the
MCU waiting for that stops it issuing host commands to the mixer?** It has the
same emulated time and diverges in behaviour, so it is reacting to something it
reads back. The obvious candidate is the mixer's host flags HF2/HF3, which
mdLib mirrors into the UC-visible ISR (`hdiUcReadIsr`, mddsp.cpp) — if the
mixer never sets them the MCU never sends, and the loop never starts.

Instrument the UC side: what does it read from the host port, and what does it
branch on, across ticks 22-26 in both engines. `mixVec12` is the readout for any
candidate fix; a working one has it climbing toward the JIT's ~2500/tick.

## Session 3, part 17 — the bootstrap that never happens, and the final state

### HF2/HF3 are not the branch condition

Measured (`MD_HF`): `mixHfSeen = 0` for the whole run in BOTH engines. The UC
never sees those flags set, so whatever it waits on, it is not them. Ruled out.

### What the UC is actually waiting for: a word from the mixer

`MD_TX` counts the DSP->UC path on the mixer (`calls` = UC polled, `hadTx` = the
mixer had a word, `sent` = it was handed over, `blocked` = the UC latch was
full):

```
tick     JIT calls/hadTx/sent/blocked      INT calls/hadTx/sent/blocked
14           6,303 /  57 /  57 / 0             156 /   0 /   0 / 0
18           6,303 /  57 /  57 / 0          97,379 /  59 /  59 / 0
22           6,303 /  57 /  57 / 0          97,379 /  59 /  59 / 0
24          38,195 / 130 / 130 / 0          97,379 /  59 /  59 / 0
26          97,394 / 299 / 299 / 0          97,632 /  61 /  61 / 0
```

`blocked = 0` everywhere: nothing is being dropped or refused. Both mixers
produce about the same handful of words early (57 vs 59). At tick 24 the JIT's
mixer starts producing more (130, then 299) and the UC's polling ramps with it.
The interpreter's mixer stays at 59 and its UC, which had already burned 97,379
polls by tick 18 against the JIT's 6,303, simply keeps waiting.

### The shape of the real problem

The dependency is mutual and it has to be bootstrapped:

```
the UC waits for a word from the mixer (polls ISR for RXDF)
the mixer produces that word only once its program advances
its program advances via the receive chain
the receive chain is started by host commands
the UC issues host commands only after it gets that word
```

The JIT crosses this at tick 24 and the interpreter never does. Neither side is
broken in isolation — every individual mechanism measured in this session
(transport, DMA, handshake, interrupts, flags) is either correct or has been
made correct, and `blocked`/`discarded`/`pendMax` counters are clean everywhere.
What differs is only whether the two sides happen to meet.

This is why the JIT "works": not because it is more accurate, but because it is
fast enough that the two sides meet on the first attempt. That is the single
most important fact in this document for anyone picking it up.

### Final state of session 3

```
interpreter, all gates OFF:   3380 bytes, mixerPC 9da   (unchanged from start)
JIT, all gates OFF:          26894 / 22090  PASSES
dsp56kTestRunner:             exit 0
```

**MD does not boot under the interpreter.**

Fixed and verified along the way, none of which was sufficient:
- the per-host-word drain cost (145 -> 6.5 cycles), `MD_DRAIN_MINSTEP`
- host-word data loss (538 -> 0) and lumpy cycle delivery, `MD_HOST_BACKLOG`
- the ESSI link flood (1042 -> 113 frames), `MD_PORTC_RELAX`

Excluded with controls, not argument: frame-sync fast-forward, scheduler
granularity, bounded DO, ESSI/DMA rate, lost Port C edges, the RX interrupt
latch, engine-dependent DMA pacing, Port C edge collapsing, HF2/HF3 flags,
dropped or blocked interrupts, and a full HDI08 receive ring.

### Resume here

Find what the JIT's mixer executes at tick 24 that produces its 73 extra TX
words, and why the interpreter's mixer — alive, on its own program, with a
healthy transport and steady cycles — does not reach it. `MD_TX hadTx` is the
readout: a working fix has the interpreter's climbing past 59 at tick 24.
Compare mixer PC histograms between engines restricted to ticks 22-26.

## Session 3, part 18 — the divergence is a command code, and the clamp is not tunable

### Diffing executed mixer code names the branch

PC histograms for both engines over the same 3-second window, diffed. Only 16
PCs are executed by the JIT's mixer and NEVER by the interpreter's. The hottest:

```
000a01 / 000a00   n=34,031      a loop the interpreter never enters
000095 / 97 / 99 / 9b   n~6,183  the fall-through of one branch
0006cc, 000300, 0002fd, 0002de, 000a06, 0006bc, 0006cd, 0006f6, 00039d, 000309
```

Disassembling the branch:

```
90: move x:(r0)+,b      ; read a command word from a queue
91: move a,y:>$1c4
93: cmp #<$6,b
94: bne int_00009c      ; the interpreter ALWAYS takes this
95: move y:>$1c6,b      ; the JIT falls through -- command == 6
97: move b,r5
98: add #<$20,b
99: move b,y:>$1c6
9b: bra int_0000a2
```

The mixer dispatches on a command code and **the interpreter never sees code
6**. This is a DATA difference, not a timing one: the command stream itself
differs, which is precisely the host commands the MCU never issues
(474 against 15,204). The 0xa00 loop is what that branch leads to.

So the firmware is not mistiming anything. It is correctly processing a command
stream that is missing most of its commands.

### The clamp is brittle and cannot close the gap

Sweeping `MD_HDI08_SLACK` against the host-command count:

```
slack        panel     mixVec12      note
1024          3160          461
2048 (dflt)   3380          474
3072             -            -      HANGS
4096             -            -      HANGS
8192             -            -      HANGS
1e9 (off)     3160           41
```

A narrow working band at 1024-2048, everything above it deadlocks, and
disabling it drops the count tenfold. Nothing approaches the JIT's 15,204. Also
retested: `MD_MAX_INSTR_PER_BLOCK=4`, which earlier made the UPLOAD match the
JIT tick-for-tick, gives mixVec12=41 — matching the JIT on upload timing makes
the metric that matters ten times worse. This is not a tuning problem and must
stop being treated as one.

### Bottom line for whoever resumes

The failure is a bootstrap that never completes, and it is now pinned to a
single observable: **the MCU issues 474 host commands where the JIT issues
15,204, and the mixer consequently never receives command code 6.**

Everything else in this document is either fixed, excluded, or downstream of
that. The remaining work is on the ColdFire side: establish what the MCU is
executing while it burns 97,379 host-port polls by tick 18 (the JIT burns
6,303 in the same emulated cycles), and what condition would let it proceed to
issue command 6. That is a ColdFire trace, not another DSP experiment.

## Session 3, part 19 — the ColdFire is stuck at one address: ucPC 0x734

Histogrammed the ColdFire's PC at every host-port ISR read (`MD_UCPOLL`,
mddsp.cpp `hdiUcReadIsr`). Tick 18, same phase in both engines:

```
ucPC      JIT        INTERP
0x734    5,618      96,694     <-- the only difference
0x720      389         389
0x81e      232         232
0x8e4        4           4
0x93a        1           1
```

Every other poll site is IDENTICAL, to the count. The MCU's divergence is one
loop, at one address. It is not generally behind or generally slow: it does
exactly the same work everywhere else and spins seventeen times longer in this
single place, waiting for a condition the interpreter never satisfies.

Combined with parts 16-18, the chain is now pinned end to end with a named
address at each link:

```
the ColdFire spins at ucPC 0x734 waiting on the mixer's host port
  -> it therefore issues 474 host commands instead of 15,204
     -> the mixer never receives command code 6 (its dispatch at P:0x93)
        -> it never enters the 0xa00 loop, and never arms DMA channel 5
           -> ~13x fewer mixer interrupts; the DMA4 receive window stays shut
              -> the producer is never released from its Port C poll at P:0xbb
                 -> the ESSI link floods (1042 frames against a steady 5)
                    -> the mixer's mainline cannot complete between DMA0
                       interrupts; the third sends it to P:0x9da
```

### What to do next, precisely

Disassemble the ColdFire at 0x734 and find which ISR bit it tests. The bits it
can see are RXDF (a word from the mixer), TXDE/TRDY (transmit ready, derived
from HRX depth in `hdiUcReadIsr`) and HF2/HF3 (measured: never set in either
engine, so not these). RXDF is the likely one, since `MD_TX` shows the mixer
sending 57-59 words early in both engines and then only the JIT's continuing.

The two candidate readings, which the disassembly will settle:

1. The MCU waits for a word the mixer would only send after processing a
   command the MCU has not sent — a genuine bootstrap deadlock that the JIT
   escapes on timing alone. If so the fix is in how the rendezvous is modelled,
   not in any single mechanism.
2. The MCU waits on a flag mdLib derives incorrectly. `hdiUcReadIsr` composes
   RXDF from `canReceiveData()` and TXDE/TRDY from `rxData().size()`; the HREQ
   path it mentions is explicitly unmodelled. A wrong bit here would strand the
   MCU exactly like this while every other poll site behaved normally, which
   matches the measurement well.

Reading 2 is the cheaper one to test and fits the evidence that every other UC
poll site is identical. Start there.

### Reading 2 checked and REJECTED: the flags are derived correctly

`mc68k::Hdi08::canReceiveData()` returns `(raw ISR & Rxdf) == 0`, and
`Hdi08::writeRx()` latches a queued word immediately whenever the latch is free.
So mdLib's line

```cpp
_isr = (_isr & ~Rxdf) | (m_hdiUC.canReceiveData() ? 0 : Rxdf);
```

is effectively a no-op copy of an already-correct bit. RXDF does reflect a word
waiting for the host. The flag derivation is not the bug.

That leaves reading 1: a genuine bootstrap dependency. The MCU at 0x734 waits
for a word the mixer sends only after processing a command the MCU has not yet
issued, and the JIT clears it on timing alone. Both mixers send 57-59 words
early and only the JIT's continues past that point, which is consistent: the
first exchange happens in both, and only one of them gets far enough to keep the
loop turning.

If that holds, no single mechanism in this emulator is wrong, and the fix is a
decision about the timing model rather than a defect repair — which is why every
individual mechanism measured in this session has come back either correct or
correctable without changing the outcome.

## Session 3, part 20 — the timing-model knob, and why this is not tunable

Implemented `MD_DSP_LEAD=<factor>` (mdhardware.cpp, schedStep): divide each
DSP's frame position so it must execute `factor` times as many cycles to reach
the same position, i.e. let the DSPs run that much faster relative to the MCU.
This is the direct test of "the JIT wins the rendezvous on speed".

```
lead    panel   mixerPC   mixVec12
1.0      3380     9da        474
1.5        -        -        HANGS
2.0      3160     247         20     <- mixer ALIVE, out of the error loop
JIT      4204     179     15,204
```

At 2.0 the mixer never reaches the error loop at all, and host commands
nonetheless fall from 474 to 20. More DSP progress, fewer commands. At 1.5 the
machine deadlocks outright.

That is non-monotonic in both directions, and it is the same pattern as every
other knob tried in this session:

```
MD_HDI08_SLACK   1024:461  2048:474  3072+:HANG  off:41
MD_MAX_INSTR_PER_BLOCK=4 (upload matches the JIT exactly):        41
MD_DRAIN_MINSTEP (per-word cost matches the JIT):                 45
MD_DSP_LEAD      1.0:474   1.5:HANG  2.0:20
```

Every setting that makes the interpreter resemble the JIT on one measured axis
makes the outcome worse, and several deadlock. A system whose response to a
monotone parameter is non-monotone and discontinuous is not mistuned; the
knobs are interacting with a fragile mutual dependency rather than driving it.

**Conclusion: this cannot be fixed by tuning, and should not be attempted
again.** The rendezvous itself has to be made robust — so that the boot does
not depend on the two sides happening to meet within a window — or the
dependency has to be broken. That is a design change to mdLib's transport, not
a parameter choice, and it needs its own validation against the MM path and the
other synths sharing this code.

`MD_DSP_LEAD` is left in the tree, default 1.0, as the cheapest way for a
future session to re-test any hypothesis about relative speed without rebuilding
the argument from scratch.

## Session 3, part 21 — Monomachine under the interpreter: JIT passes, interpreter SIGSEGVs

Widening the question from MD to "does the interpreter path work at all", since
that is what iPad actually needs:

```
mmBootFirmwareTest, JIT:          PASS, cold boot, edited kit and state-restored boot
mmBootFirmwareTest, interpreter:  SIGSEGV (exit 139), consistently, after
                                  ~5,048,000 host words
```

Up to the crash the MM transport looks healthy — `drainCyclesPerWord` 0.4-1.1,
nothing like MD's 145 — so this is not the MD drain problem reappearing.

**Attribution is not fully settled.** The crash could in principle come from
this session's instrumentation. Evidence that it does not:

- every behavioural change is env-gated and OFF in this run;
- the non-gated additions are plain counter increments;
- the two genuinely thread-unsafe diagnostics (`m_ucPollPc`, the per-drain
  `drainPcs` map) were gated behind env vars specifically because MM runs the
  DSP on its own thread — and the crash persists unchanged with them off;
- the JIT build, which carries exactly the same instrumentation, PASSES.

That last point is the strongest: identical instrumentation, one engine crashes
and the other does not. It points at the interpreter path rather than at the
counters. It is not proof. A pristine-tree run would settle it; note that
`git stash -u` REMOVES the untracked `mdBench.cpp` / `iosmain.mm` that CMake
references and breaks the build — restore with `git stash pop` (verified
recoverable, nothing was lost) or exclude untracked files.

### What this means for the original question

"Confidence with the MD interpreter for iPad" is not just unmet for MD; the
interpreter path has a second, independent failure on the Monomachine, which is
the machine that was previously believed to be the closer one. Anyone planning
iOS work on this fork should treat interpreter support as unproven for BOTH
Elektron targets until these are separated and fixed.

Test command:

```sh
GEARMULATOR_MM_FIRMWARE_BIN=<MM OS 1.32b .bin> \
  build-interp/source/elektron/md/mdLibTest/mmBootFirmwareTest
```

## Session 3, part 22 — FIXED: the interpreter no longer crashes the host on a bad PC

The MM segfault is diagnosed and the crash itself is fixed.

### Diagnosis

The macOS crash report puts the fault inside `dsp56k::DSP::execOp`, reached from
`schedStep -> processAudio`, as `EXC_BAD_ACCESS` on a wild address. `execOp`
indexes `m_opcodeCache[currentOp]` with no bounds check, and that vector is
sized to `mem.sizeP()`, so a PC outside P memory is an out-of-bounds read of a
function pointer which is then called.

The JIT path has had a guard for exactly this since before this session
(`g_jitPcGuard` -> `onInvalidPC`, dsp.h). **The interpreter had no equivalent.**
That asymmetry is why the same firmware kills the process on one engine and not
the other.

### Fix

Added the matching check in `DSP::execOp` (dsp.cpp), one compare on a hot path,
branch never taken in normal operation:

```cpp
if(ASMJIT_UNLIKELY(currentOp >= m_opcodeCache.size()))
{
    onInvalidPC(currentOp);
    return;
}
```

`m_opcodeCache` is sized to `mem.sizeP()`, so this condition means the PC really
has left valid P memory, which is what `onInvalidPC` already reports and halts
on. Not env-gated: this is a correctness fix, not a diagnostic.

### What it turned the crash into

```
[DSP] INVALID PC ff0000 (valid P memory is 0 - 7fffff), DSP halted.
sr=0880d8 sp=1 omr=004d0d mode=0 instructions=1996241008
```

`0xFF0000` is the DSP56303's on-chip bootstrap ROM, and the reset vector at P:0
is `jmp $ff0000` (visible in the vector dump in part 16). So the MM DSP takes a
RESET about two billion instructions in and jumps to a bootstrap ROM this
emulator does not map there — it maps the loader at 0x14ff00 instead. That is
the next MM question, and it is now a clean halt with full register state
instead of a dead host process.

### Verified after the fix

```
dsp56kTestRunner:                 exit 0
MD interpreter:                   3380 bytes  (baseline unchanged)
MD JIT:                           26894 / 22090  PASSES
MM interpreter:                   halts with a diagnosis, no SIGSEGV
```

### Why this matters for iOS specifically

On the device an out-of-bounds call through a garbage function pointer is an
immediate process kill with no diagnosis, and the interpreter is the ONLY engine
available there. Every wild-PC bug in any firmware now reports its PC and halts
that DSP instead of taking the app down. This does not make MD boot, but it
removes a whole class of unrecoverable iOS failures and makes the remaining ones
diagnosable on-device.

## Session 3, part 23 — more time does not help, and the final ledger

Ran the all-alive configuration (`MD_HOST_BACKLOG=1`) for 60 emulated seconds,
600 ticks, more than three times the readiness test's window:

```
tick 600: bytes=3160 mixerPC=9da producerPC=bd
          mixerInstr=2,063,678,265  ucCycles=2,400,000,004
```

Unchanged. It is a hard fault, not slowness, and no amount of runtime closes it.
MD also never triggers the new invalid-PC guard (0 reports), so the wild-PC class
of failure is not involved on this machine.

## SESSION 3 FINAL LEDGER

**MD does not boot under the interpreter.** 3380 bytes against the 26,894 a
passing JIT run reaches.

### Fixed (real defects, verified)

1. **Interpreter PC guard** (dsp.cpp, NOT gated) — `execOp` indexed
   `m_opcodeCache` with an unchecked PC and called the result. The JIT had
   guarded this for years; the interpreter had not. Turns a host-process SIGSEGV
   into a diagnosable halt. Caught the MM crash and named it.
2. **Per-host-word drain cost** 145 -> 6.5 cycles (`execMinimalStep`,
   `MD_DRAIN_MINSTEP`).
3. **Host-word data loss** 538 -> 0, and lumpy cycle delivery made
   JIT-identical (`MD_HOST_BACKLOG` + the UC stall).
4. **ESSI link flood** 1042 -> 113 frames (`MD_PORTC_RELAX`).

### Excluded with controls

Frame-sync fast-forward; scheduler granularity; bounded DO; ESSI/DMA rate;
lost Port C edges; the RX interrupt latch; engine-dependent DMA pacing; Port C
edge collapsing; HF2/HF3 flags; dropped or blocked interrupts; a full HDI08
receive ring; incorrect TXDE/TRDY derivation; insufficient runtime.

### Proven not tunable

Twenty-plus measured configurations across four independent knobs. Every setting
that makes the interpreter resemble the JIT on one axis makes the outcome worse,
and several deadlock. The response is non-monotone and discontinuous in both
directions.

### The fault, with a measured address at every link

```
ColdFire spins at ucPC 0x734 waiting for a word from the mixer
 -> issues 474 host commands instead of 15,204
   -> the mixer never sees command code 6 at its dispatch (P:0x93)
     -> never enters the P:0xa00 loop, never arms DMA channel 5
       -> ~13x fewer mixer interrupts; the DMA4 window stays shut
         -> the producer is never released from its Port C poll (P:0xbb)
           -> the ESSI link floods, 1042 frames against a steady 5
             -> the mixer's mainline cannot complete between DMA0 interrupts
               -> the third one sends it to the error loop at P:0x9da
```

### The one-sentence conclusion

No individual mechanism in this emulator is wrong; the boot depends on the
ColdFire and the mixer meeting inside a window that the JIT clears on speed
alone, and making that rendezvous robust — or removing the dependency — is a
design change to mdLib's transport, not a defect repair or a parameter choice.

### Also established

Monomachine does not run under the interpreter either: it resets to the
DSP56303 bootstrap ROM at 0xFF0000 about two billion instructions in, an address
this emulator does not map. Interpreter support is unproven for BOTH Elektron
targets. That is the honest state of "confidence with the MD interpreter for
iPad".

## Session 3, part 24 — granularity matched exactly, still no change

One assumption was worth attacking directly: both engines are handed IDENTICAL
emulated time by the scheduler (ucCycles and DSP cycles agree at every tick), so
the difference between them cannot be timing. What differs is how far the DSP is
advanced per host-port step. The interpreter offered only a fixed
`maxInstructionsPerBlock` slice (overshoots a short block) or a single
instruction (undershoots a long one); a JIT `exec()` advances exactly one BASIC
BLOCK.

Implemented `DSP::execBasicBlockStep()` (dsp.h) — run instructions until the PC
leaves the straight line, i.e. real JIT block semantics — and wired it into the
drain as `MD_DRAIN_BLOCK=1`.

```
MD_DRAIN_BLOCK=1                    HANGS (with the clamp)
MD_DRAIN_BLOCK=1 + clamp off        3160 bytes, mixVec12=41
MD_DRAIN_MINSTEP=1 + clamp off      3160 bytes, mixVec12=45
baseline                            3380 bytes, mixVec12=474
JIT                                 4204 bytes, mixVec12=15,204
```

Matching the JIT's granularity EXACTLY changes nothing, and is indistinguishable
from the one-instruction variant. So granularity is not the determinant either,
and the "the interpreter advances the DSP differently per host step" theory is
now closed along with the timing one.

Left in the tree, default off. It is the correct primitive to have regardless:
if a future change needs JIT-equivalent stepping, this is it.

### Final verification (all gates OFF)

```
dsp56kTestRunner:  exit 0
MD interpreter:    3380 bytes, mixerPC 9da
MD JIT:            26894 / 22090  PASSES
```

## Session 3, part 25 — peripheral service cadence tested and excluded

Reframing note: the interpreter has NEVER worked for MD/MM. This is not a
regression to find, it is behaviour to implement. mdLib's transport was written
and hand-tuned against JIT semantics.

That made peripheral service cadence the best remaining structural candidate.
`IPeripherals::isDue()` is tested against the INSTRUCTION counter
(`_instructions >= m_targetClock`) while `execPeripherals()` schedules the next
service as `instructions + <a cycle-valued delay>`. The two engines advance that
counter differently: the interpreter creeps by one and services a peripheral on
the exact instruction it comes due; the JIT jumps by a whole block and services
it up to a block LATE.

Added `MD_PERIPH_BATCH=N` (dsp.h `execPeriph`, global in dsp.cpp, default 1) to
reproduce the JIT's lateness in the interpreter:

```
batch=1 (unchanged)   3380 bytes   mixVec12=474
batch=8               3160 bytes   mixVec12=465
batch=20              HANGS
JIT                   4204 bytes   mixVec12=15,204
```

No improvement, then deadlock. **Peripheral service cadence is excluded.**

### Upstream research (this session)

- The working tree is at upstream HEAD: parent = PR #83 merge (2026-09-15),
  `source/dsp56300` = `cf0755e` (2026-09-14). There is no upstream fix to adopt.
  PR #83 is a submodule bump plus audio-I/O work, not a boot fix.
- `joelanders/gearmulator-md-mm` has ZERO issues mentioning the interpreter,
  non-JIT builds, iOS, or DSP56K_FORCE_INTERPRETER. MD/MM under the interpreter
  has never been exercised upstream.
- iOS cannot JIT at all (no executable pages for a non-entitled process), so a
  JIT build fails at runtime there. The interpreter is not a fallback on iPad,
  it is the only engine.

Conclusion: nothing to inherit. Making MD/MM run interpreted is new work on this
fork, and the transport is the part that has to be written for it.
