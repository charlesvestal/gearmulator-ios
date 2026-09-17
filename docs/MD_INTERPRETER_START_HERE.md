# MD/MM interpreter — START HERE

Read this file, not `MD_INTERPRETER_HANDOFF.md`. That one is a 2,100-line
chronological evidence archive from three sessions; consult it only when you
need the raw measurement behind a claim here. This file is the briefing.

## The job

Make the **Machinedrum boot and produce audio under the DSP56300 interpreter**,
to prove iPad viability. iOS cannot JIT at all (the kernel will not map an
executable page for a non-entitled process, so a JIT build fails at runtime),
so the interpreter is the ONLY engine available on device. This is not a
regression to find: **MD has never booted interpreted, by anyone.** (MM does
boot and make audio interpreted — see the corrected section at the end. Its
constraint is throughput, not boot.) Upstream
has zero issues mentioning the interpreter, and this fork's tree is already at
upstream HEAD. It is unimplemented behaviour, not a broken feature.

**Constraint: commit freely, but do NOT push anything.** That has been in force
all along and nothing has been pushed.

## Where everything is

```
/Volumes/ExtFS/charlesvestal/github/schwung-parent/md-interp-work/
  mdmm/                 the working tree (fork of gearmulator + mdLib)
  mdmm/build-interp/    configured with DSP56K_FORCE_INTERPRETER=1
  mdmm/build-jit/       the reference engine
  artifacts/mdrom/      elektron_sps1-1uw_os1.63.bin (MD), elektron_sfx6-60_os1.32b.bin (MM)
  logs/ traces/         prior output
  reference-binaries/   pre-move binaries for byte comparison

/Volumes/ExtFS/charlesvestal/github/schwung-parent/gearmulator-ios/
  docs/MD_INTERPRETER_START_HERE.md   this file
  docs/MD_INTERPRETER_HANDOFF.md      the evidence archive (27 parts)
  patches/md-mm-current-state.patch   full snapshot of the working tree diff
```

Nothing lives in /tmp any more. 27 commits exist on branch `ios-bench`
(`ed7d14d`..`d9ada4d`), unpushed.

## Reproduce the baselines first (do this before anything else)

```sh
cd /Volumes/ExtFS/charlesvestal/github/schwung-parent/md-interp-work/mdmm
ROM=../artifacts/mdrom/elektron_sps1-1uw_os1.63.bin

# unit suite — must be exit 0
build-interp/source/dsp56300/source/dsp56kTestRunner/dsp56kTestRunner

# JIT — PASSES: fresh 26894 bytes, repeat 22090
GEARMULATOR_MD_FIRMWARE_BIN=$ROM MD_TEST_SECONDS=18 \
  build-jit/source/elektron/md/mdLibTest/mdPanelReadinessFirmwareTest

# interpreter — FAILS: 3380 bytes, mixer ends in the error loop at P:0x9da
GEARMULATOR_MD_FIRMWARE_BIN=$ROM MD_TEST_SECONDS=18 \
  build-interp/source/elektron/md/mdLibTest/mdPanelReadinessFirmwareTest
```

A full 18-second run takes several minutes of wall clock. Always run it in the
background with a watchdog; never pipe a running test through `grep` (block
buffering has faked a hang here before) — redirect to a file and grep that.
Benchmark only on an idle machine: machine load has produced a 9.4x swing in
measured throughput on identical binaries.

## The instrument — use this, not per-tick counters

`MD_UCSTREAM=1` logs the CONTENT of every host-port event the ColdFire can
observe. Those events plus its own timers are the MCU's ONLY inputs, so the
first index at which two engines' streams differ by content **is** the root
divergence, by construction. Three sessions of per-tick aggregate counters could
not see it; this found it in one run.

```sh
for c in jit interp; do
  MD_UCSTREAM=1 MD_UCSTREAM_MAX=250000 GEARMULATOR_MD_FIRMWARE_BIN=$ROM \
    MD_TEST_SECONDS=4 build-$c/source/elektron/md/mdLibTest/mdPanelReadinessFirmwareTest \
    2>&1 | grep -a '^UCS ' > /tmp/ucs-$c.txt
done
# then diff on (type, value) — ignore ucPC/ucCyc, they are context
```

Current readings:

```
configuration                                     first mismatch
baseline                                                    1552
MD_DRAIN_MINSTEP=1 MD_HDI08_SLACK=1000000000                2149   <- best
  + MD_TIMED_HOSTRX / MD_LIVE_UCCYCLE / MD_HOST_BACKLOG     2149   (no movement)
  + MD_IRQ_BLOCK_PHASE                                      2149   (no movement)
```

With MINSTEP the streams are **byte-identical through index 2148** — every
delivered word, in order, at the same UC cycle.

## What is actually wrong

The producer answers the MCU's poll with a status value. Both engines walk the
same sequence; the interpreter is simply LATE to each transition:

```
delivered values   JIT: 732x 0, 14x 1, 6x 2, 2x 3, 2x 0x65
                   INT: 178x 0, 15x 1, 8x 2, 5x 3,  never 0x65
```

At index 2149 the JIT's producer reports `1` (its first non-zero — a state
change) while the interpreter's still reports `0`. The interpreter does reach
1, 2 and 3 later, so nothing is lost or blocked; it never reaches `0x65`, the
state the boot needs, before the machine collapses downstream.

The collapse, with a measured address at every link:

```
ColdFire spins at ucPC 0x734 waiting for a word from the mixer
 -> issues 474 host commands instead of 15,204 (identical ucCycles at every tick)
   -> mixer never receives command code 6 at its dispatch (P:0x93: cmp #6,b / bne)
     -> never enters the P:0xa00 loop, never arms DMA channel 5
       -> ~13x fewer mixer interrupts (interrupts here ARE DMA completions)
         -> mixer's DMA4 receive window mostly shut
           -> producer never released from its Port C poll at P:0xbb
             -> inter-DSP ESSI link floods (1042 frames vs a steady 5)
               -> mixer mainline cannot complete between DMA0 interrupts
                 -> the third one -> error loop at P:0x9da
```

## The conclusion the evidence supports

**No individual mechanism in this emulator is wrong.** ~15 candidate causes were
excluded with controls, four real defects were fixed, and the boot metric did
not move. mdLib's MCU<->DSP transport is **budget-driven** ("advance this DSP N
cycles and hope") where every working synth in this tree — xtLib, virusLib — is
**condition-driven** ("wait until the fact is true"), and mdLib's version was
hand-tuned against JIT timing.

An expert consult corrected the earlier "the JIT wins by being fast" framing,
which was wrong and never made sense given both engines see identical cycle
counts. The real mechanism is **machine-time phase error**: how far a DSP has
overshot the shared clock when its state becomes UC-visible — ~120 cycles under
the JIT, up to 2048 or the 100k clamp under the interpreter. Identical per-tick
totals say nothing about WITHIN-tick event timing, and that is what firmware
observes.

## THE TASK

Rewrite mdLib's MCU<->DSP rendezvous to be condition-driven, the way
`xtLib`/`virusLib` are. Three structural properties they have and mdLib does
not (see `wLib/wHardware.cpp:44` `ucYieldLoop`, `xtLib/xtDSP.cpp:146-220`):

1. **Every rendezvous closes on a condition, not a budget.** `waitDspRxEmpty()`,
   `hdiSendIrqToDSP()`, `onUCRxEmpty()` are unbounded waits on the *event*.
   There is no window to miss. mdLib replaces each with "advance the DSP <=100k
   cycles and hope", plus clamps that can *refuse* the only progress-making
   component — every deadlock in the archive is a clamp refusing.
2. **UC time is elastic.** While the xt UC waits, its clock does not advance, so
   the effective DSP:UC ratio during boot is unbounded and firmware-invisible.
   mdLib pins that ratio to a constant during boot, which is exactly when the
   real machine's ratio is set by handshakes rather than clocks.
3. **The DSP never runs ahead of anything that can observe it.** The threaded
   DSP free-runs but the UC only samples it through blocking conditions. mdLib's
   inline drains create a "read the DSP's future state" path.

**The blocker is reentrancy**, and it is an ordinary engineering problem:
`writeWordToDsp` is called from inside `advance() -> schedStep() -> processUC()
-> m_uc.exec()`. The single-threaded `ucYieldLoop` equivalent is NOT "stall the
UC via cycle bookkeeping" (that was tried — part 10 — and is still budget-based)
but "run the whole-machine interleave from inside the wait until the predicate
is true, with the UC parked". Two viable shapes:

- make `schedStep` reentrant with the UC excluded from selection while parked; or
- an explicit continuation/state machine so the UC's poll returns and retries.

**Do NOT re-run threading.** It is excluded, and it is not the point — every
other synth's *condition-driven* structure is the point, not its thread.

Readouts for any candidate fix, in order of decisiveness:
1. first stream mismatch index must move well past 2149, or vanish
2. `mixVec12` (host commands) climbing from 474 toward the JIT's 15,204
3. panel bytes past 3380 toward 26,894

## Do not retry these (all excluded with controls)

Frame-sync fast-forward; scheduler granularity; bounded DO; ESSI/DMA rate;
lost Port C edges; the RX interrupt latch; engine-dependent DMA pacing; Port C
edge collapsing; HF2/HF3 flags; dropped or blocked interrupts; a full HDI08
receive ring; TXDE/TRDY derivation; insufficient runtime (60s tested); basic
block stepping; peripheral service cadence; threading. And **tuning**: 20+
configurations across 4 knobs, response non-monotone and discontinuous — every
setting that makes the interpreter resemble the JIT on one axis makes the
outcome worse, several deadlock.

## Keep these (real fixes, verified)

- **Interpreter PC guard** (`dsp.cpp` `DSP::execOp`, NOT gated). `execOp`
  indexed `m_opcodeCache` with an unchecked PC and *called the result*; the JIT
  had guarded this for years, the interpreter had not. Turns a host-process
  SIGSEGV into a diagnosable halt. **This one is independently shippable and
  matters most on iOS**, where the interpreter is the only engine and a garbage
  function pointer is an instant kill with no diagnosis.
- `do_exec` bounded-DO accounting fix; rate-limited `LOG_ERR_BASE`; macOS-only
  `mach_vm`; asmjit iOS header fix.

## Env gates that exist (ALL default OFF; none of them fix the boot)

```
MD_DRAIN_MINSTEP     minimal-step HDI08 drain; 145 -> 6.5 cycles/word.
                     Best single lever on the stream metric. Deadlocks with the
                     clamp, so pair with MD_HDI08_SLACK=1000000000.
MD_HOST_BACKLOG      lossless host-word queue + UC stall. Data loss 538 -> 0,
                     cycle delivery made JIT-identical, mixer stays out of 9da.
MD_PORTC_RELAX       relaxed Port C release gate. Link flood 1042 -> 113 frames.
MD_TIMED_HOSTRX      port MM's timed publication to MD. Moves host commands
                     474 -> 642, words 59 -> 123. DEADLOCKS at tick 28.
MD_LIVE_UCCYCLE      hostCurrentCycle() from the UC's live per-instruction
                     counter instead of m_schedUcCyclesDone, which only advances
                     at QUANTUM boundaries. Fixes that deadlock. **This is a real
                     modelling defect worth keeping regardless of the boot.**
MD_IRQ_BLOCK_PHASE   dispatch interrupts only at control-flow boundaries, as the
                     JIT does, instead of before every instruction.
MD_DSP_LEAD          let the DSPs run N times as fast relative to the MCU.
MD_PERIPH_BATCH      batch peripheral due-checks.
DSP_PC_HIST          per-PC execution histogram, dumped at exit.
DSP_DCR_TRACE        every DMA control register change with its source PC.
MD_DISASM            "dsp,startHex,endHex,tick" — disassemble a P range once.
MD_UCSTREAM          the stream logger described above.
```

## Known bug found but NOT fixed (low risk, cheap)

`DSP::exec()` interpreter path, `dsp.h:262`: the first branch
`if(!config.maxDoIterations || !sr_test_noCache(SR_LF)) { execInterpreter(); return; }`
makes the following block — whose comment claims to "match the JIT's granularity
outside hardware loops" — **unreachable dead code**. Actual behaviour: 1
instruction outside hardware loops, up to 32 inside. Several "granularity ruled
out" results in the archive were measured on a binary that did not do what its
comments say.

## Also true — CORRECTED

**Monomachine DOES boot and make audio under the interpreter.** It was measured
earlier at 0.737x real time on the bench and 0.463x in-app, cycle-verified, and
audio was confirmed audible on device. **MM's problem is THROUGHPUT, not boot.**
An earlier draft of this file claimed MM "does not run interpreted" — that was
wrong, and the instruction count should have given it away.

What is true is narrower: `mmBootFirmwareTest` (a three-phase test: cold boot,
edited kit, state-restored boot) halts under the interpreter after
**1,996,241,008 instructions and 5,048,000 host words** — far beyond any boot —
reporting `INVALID PC ff0000`. That is the DSP56303 on-chip bootstrap ROM, which
this emulator does not map there (it places the loader at 0x14ff00), i.e. the
DSP took a reset deep into a long run. Before the PC guard this was a SIGSEGV.

So it is a late-run / state-restore issue in a long test, NOT a boot failure,
and it does not contradict MM working on device. Reproducer:

```sh
GEARMULATOR_MM_FIRMWARE_BIN=../artifacts/mdrom/elektron_sfx6-60_os1.32b.bin \
  build-interp/source/elektron/md/mdLibTest/mmBootFirmwareTest
```

Caveat, stated honestly: a pristine-tree run was never completed to fully rule
this session's instrumentation out of that crash. The JIT build passing with
identical instrumentation is strong evidence it is not ours, but it is not
proof. Note `git stash -u` REMOVES the untracked `mdBench.cpp`/`iosmain.mm` that
CMake references and breaks the build — recover with `git stash pop`.

## Hygiene that matters here

- Idle machine only; one test at a time; no concurrent builds.
- Never pipe a running test through `grep`; redirect and grep the file.
- Compare engines at the SAME tick, and quote the env flags with every number.
- Existing logs contain NULs: use `grep -a`.
