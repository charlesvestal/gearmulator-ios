# MD/MM interpreter — START HERE

> ## STATUS: SOLVED 2026-09-17. The Machinedrum boots under the interpreter.
>
> **Everything below this box predates the fix and is kept only as the record of
> how it was found. Do not act on it.** In particular the collapse chain, the
> "no individual mechanism is wrong" conclusion, and THE TASK (the rendezvous
> rewrite) are all obsolete: the cause was a single instruction-level bug, and
> nothing about it was a timing problem.
>
> ### The bug
>
> `op_Movep_ppea` (dsp_ops_move.inl) routed the effective-address side of a
> `movep` as plain memory, while the JIT routes it through
> `readMemOrPeriph`/`writeMemOrPeriph` (jitops_move.cpp:465, jitops_mem.cpp:35/77)
> which test `isPeriphAddress()`. So **peripheral-to-peripheral `movep` silently
> wrote into DSP memory under the interpreter and worked under the JIT.**
>
> The mixer's DMA-arming routine is exactly that shape:
>
> ```
> 9aa  movep x:<<$ffffc6,x:<<$ffffda   ; HRX -> DDR5 (destination)  LOST
> 9ac  movep #>$e9ac4,x:<<$ffffd8      ; imm -> DCR5 (config)       ok
> 9b1  movep x:<<$ffffc6,x:<<$ffffd9   ; HRX -> DCO5 (counter)      LOST
> 9b3  movep #>$8e9ac4,x:<<$ffffd8     ; imm -> DCR5 DE=1, arm      ok
> ```
>
> DMA channel 5 really was armed, at the right cycle -- with a destination and
> counter it never received. That is why every measurement said "arms correctly
> but at 1/18th the rate", and why three sessions of timing hypotheses could not
> find it.
>
> Fix: dsp56300 commit 9cb3112. Result, stock path, no flags:
> fresh bytes 3,380 -> 26,884 (JIT 26,894); tiles and lit match the JIT exactly.
>
> ### How it was found -- the most useful process fact here
>
> All prior work used `CMAKE_BUILD_TYPE=Release`, i.e. `-DNDEBUG`, which makes
> **all 323 asserts in dsp56kEmu no-ops.** The fork author flagged this after
> hitting the same trap. One Debug build produced the entire chain in minutes:
> `alu_mac`'s scaling assert at tick 14 -> silencing it as a diagnostic exposed
> `assert(_offset < XIO_Reserved_High_First)` in `dspWrite` at tick 25 ->
> instrumenting that named the exact writes (X:ffffda, X:ffffd9) and PCs.
>
> **Always build Debug for correctness work here.** Verified control: Debug and
> Release produce byte-identical emulated state, so asserts do not perturb the
> emulation -- Release only blinds the diagnosis.
>
> ### On device
>
> Runs on an iPad Pro 13-inch (M5), stable. Headless `mdBench`, free-running:
>
> ```
> INTERPRETER MD  audio=5.0s  wall=8.69s  realtime=0.576x  (warmup 11.87s)
>   mixer 47.2M instr/s   producer 50.3M instr/s
>
> for comparison, M1 Mac mini:  interpreter 28.2M instr/s, JIT 59.3M instr/s
> ```
>
> The iPad is 1.67x the M1 -- normal generational scaling, nothing pathological,
> and the interpreter on iPad is already at 80% of the M1 JIT's throughput.
> Needs ~1.74x for realtime parity, ~2.6x for comfortable headroom.
>
> Note the standalone app reports ~0.195x, but that is the JUCE editor live and
> the emulation clocked by the audio callback -- a real "is it keeping up"
> signal, NOT a throughput ceiling. Use the headless bench for throughput.
> Its log is written to Documents/mdbench.log on device; pull it with
> `xcrun devicectl device copy from --domain-type appDataContainer`.
>
> ### Open
>
> - **Pressing a trig crashes MD and freezes MM on device.** MM did neither
>   before the fix, which is evidence the fix put real peripheral traffic on
>   paths that were previously silent no-ops. `encoderPressFirmwareTest` (taps
>   Trigger1) ran minutes under Debug without tripping an assert, so this needs
>   a reproducer closer to the panel/UART path the device UI uses.
> - **MM still halts** with `INVALID PC ff0000` at instruction 605,667,784 --
>   byte-identical before and after the movep fix, so it is a separate bug.
> - **~1.74x throughput needed.** The JIT is only 2.1x the interpreter, which is
>   narrow for JIT-vs-interpreter and suggests shared peripheral/scheduler code
>   dominates rather than instruction dispatch. Profile before optimising.
>   `traceDivergence()` runs on every interpreted instruction.
> - **Sibling EA-routing sites**: the JIT uses readMemOrPeriph/writeMemOrPeriph
>   at jitops_alu.inl:41/43, jitops_mem.inl:56/120, jitops_move.inl:86/93/112/119.
>   The interpreter's generic MMM/RRR readMem/writeMem DO check
>   isPeripheralAddress (verified), so Movep_ppea was the only gap of that exact
>   shape -- but the rest deserve an audit.
> - **Release-path debris** to remove: a hardcoded `0x101327` write trap on every
>   DSP write (memory.cpp), an `MD_REP` cycle-range check, and an ungated
>   `MD_HOSTWORDS` fprintf. Measured at ~500 log lines/sec of emulated time, so
>   NOT a significant throughput cost -- but it is debris.

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

## CORRECTIONS from the session of 2026-09-17 (read before re-running anything)

All three baselines reproduce exactly (unit suite exit 0; JIT 26894/22090;
interpreter 3380 with the mixer at P:0x9da). Nothing below contradicts that.

**1. Score candidates on boot progress, not on the stream index.** The
"first mismatch index" is over-sensitive: at 2148 the interpreter does the SAME
thing one poll later, which is a phase slip, not a content divergence. Collapse
runs of identical (type, dsp, value) events and diff the transition sequence
instead. Better still, use `mixVec12` at a fixed tick, which tracks boot:

```
configuration                                    @tick25   @tick180  outcome
JIT                                                 1762     139410  boots
interpreter baseline                                   0        474  9da
"MD_DRAIN_MINSTEP=1 MD_HDI08_SLACK=1000000000"        20         20  9da   <- the old "best"
"MD_DRAIN_MINSTEP=1 MD_BACKLOG_LATE=1"                20         20  9da
"MD_DRAIN_MINSTEP=1"                                 665          -  wedges @25
```

The configuration this file recorded as best (stream 2149) is near-WORST on boot
progress, because `MD_HDI08_SLACK=1000000000` drives the drain to the full 100k
inline clamp and so REINSTATES exactly the overshoot `MD_DRAIN_MINSTEP` removes.
That is a likely source of the "non-monotone and discontinuous" tuning response:
the configurations were ranked on a metric that does not track boot.

**2. The root divergence is the bootstrap loader's poll, and it is measured.**
The engines are bit-identical for 10 scheduler ticks. At tick 11 the producer's
loader diverges. Aggregate DSP:UC cycle ratios are identical to 5 decimals
(2.5399), so it is not throughput. The inline HDI08 drain costs, per host word:
JIT prodMax=19, interpreter prodMax=164.

`MD_STUCK_THRESHOLD=60` shows one drain iteration, one exec() call, one PC
(14ff1b), 145 cycles. The loader's poll `brclr #0,x:<<$ffffc3,func_14ff1b` sits
inside a `dor` hardware loop, and `DSP::exec()`'s hardware-loop path runs up to
`maxInstructionsPerBlock` (32) instructions per call while the drain re-tests
its exit condition only BETWEEN calls. The dead-code note in this file was
right, and its consequence is worse than stated: granularity is 1 instruction
OUTSIDE a hardware loop and 32 INSIDE one -- backwards exactly where it matters.

**3. It is pure post-condition overshoot (new instrument, `MD_WORDLAT=1`).**
Splits each word into pre (publication -> the DSP's read of HRX) and post (that
read -> the drain returning). Producer at tick 20, identical 250,125 words:

```
                 JIT          interpreter
preTotal     2,225,029          1,251,191     <- interpreter is FASTER to hand over
postTotal        2,690         34,941,417     <- 12,990x
postMax             10                140
outside         97,567                418
```

~17% of all producer machine time is spent executing past a condition that had
already become true.

**4. Eliminated this session.** The TXDE/TRDY derivation is CORRECT (depth 0 ->
TXDE|TRDY, 1 -> TXDE, 2 -> neither). `MD_LIVE_CATCHUP=1` (new: live UC cycles in
`schedCatchUpDsp`/`schedDspClockDeadline`, which `MD_LIVE_UCCYCLE` never
touched) adds nothing over MINSTEP alone and costs ~20x throughput. Holding
words rather than destroying them (`MD_BACKLOG_LATE=1`) removes the loss
(mixLost 8830 -> 1) and the wedge, but drops mixVec12 to 20 -- back-pressure is
not the missing piece.

**5. `booted()` is vacuous as a boot-phase guard.** `DspBoot` emulates only the
on-chip bootstrap ROM: one block (measured: address 0x000100, length 0xb7), then
it returns true and `writeWordToDsp` takes over. The BULK of the firmware is
uploaded afterwards by loader code running on the DSP core. So the
"only model HREQ for the post-boot transfers" guard is true throughout the phase
it means to exempt, which is why `MD_HOST_BACKLOG` starves the loader
(prodBacklogMax 24,063, PC never leaves 14ff1b).

**6. The open blocker.** `MD_DRAIN_MINSTEP=1` alone is the best result recorded
and wedges at tick 25. First overflowing transaction there, flagless:

```
interp  depth=2 ucPC=100077c lastIsr=07 dspPC=000242 dspCyc=262964019
JIT     no overflow at all in 3 seconds
```

`isrReadsSinceLastWrite=0` in EVERY configuration including the JIT: the
ColdFire reads status once and then burst-writes from the two-instruction loop
at 0x100077a/c at ~2-5 UC cycles per word without re-checking. Across those
writes the DSP is handed ~2070 cycles per word and still does not consume,
because it is at 0x242 in firmware with the host-receive DMA unarmed -- not
polling at all. So the next question is not capacity or status, it is why the
mixer is in the wrong state to service the port.

### New env gates (all default OFF, all verified inert when off)

```
MD_WORDLAT        per-word pre/post split described above. The decisive instrument.
MD_LIVE_CATCHUP   live UC cycles for the two DSP catch-up deadlines.
MD_BACKLOG_LATE   decide to hold a word AFTER the drain has had its chance,
                  not before; needs no boot-phase predicate. Works standalone.
MD_LOADER_EXEMPT  PC-region boot-phase predicate. Correct for the first loader
                  stage only; kept as a measurement, not a fix.
```

## Hygiene that matters here

- Idle machine only; one test at a time; no concurrent builds.
- Never pipe a running test through `grep`; redirect and grep the file.
- Compare engines at the SAME tick, and quote the env flags with every number.
- Existing logs contain NULs: use `grep -a`.
