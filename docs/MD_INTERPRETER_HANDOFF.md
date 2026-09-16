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
