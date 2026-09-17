# DSP56300 interpreter — findings for upstream / the fork author

> **UPDATE, same day: the Machinedrum now boots under the interpreter.** The
> boot failure this document describes was a single instruction-level bug, not
> the timing problem the earlier analysis assumed.
>
> `op_Movep_ppea` routed the effective-address side of a `movep` as plain
> memory; the JIT routes it through `readMemOrPeriph`/`writeMemOrPeriph`, which
> test `isPeriphAddress()`. So peripheral-to-peripheral `movep` silently wrote
> into DSP memory under the interpreter only. The mixer's DMA-arming routine
> writes DDR5 and DCO5 that way, so DMA channel 5 was armed with a destination
> and counter it never received -- while DCR5, written by immediate `movep`,
> arrived normally. Hence "arms at the right cycle, at 1/18th the rate".
>
> Fix: dsp56300 commit 9cb3112. Stock path, no flags: fresh bytes 3,380 ->
> 26,884 against the JIT's 26,894, with tiles and lit matching the JIT exactly.
> Runs on an iPad Pro M5 at 0.576x realtime headless (47.2M instr/s, 1.67x the
> M1 -- normal generational scaling).
>
> Sections below are kept as the record. Part 1.1 (the `DSP::exec()` granularity
> dead code) and Part 1.3 (`onInvalidPC` halting by sleeping) are still valid
> engine issues worth upstreaming. Part 2's throughput ratio still holds. Part 3
> describes a boot failure that no longer exists.

Measurements from an attempt to run the Elektron Machinedrum and Monomachine
under the DSP56300 **interpreter** (no JIT), for an iPad port — iOS will not map
an executable page for a non-entitled process, so the interpreter is the only
engine available on device.

**The attempt was stopped.** But three of the findings are engine-level and are
useful whether or not anyone pursues an interpreter path, so they are separated
out first. All numbers were taken on an Apple M1 Mac mini (Macmini9,1), on an
idle machine, one test at a time.

Throughout: claims are marked **measured** or **inferred**. Two claims we made
earlier in this work turned out to be overstated and are corrected in Part 4.

---

## Part 0 — READ FIRST: everything below was measured on Release builds

All of this work — this session and the three before it — was done with
`CMAKE_BUILD_TYPE=Release`, i.e. `-DNDEBUG`, which turns **all 323 `assert()`s
across 55 files in `dsp56kEmu` into no-ops.** The fork author flagged this after
hitting the same trap ("fought glitches forever ... turns out I was using release
build configurations the whole time"). It is the single most useful piece of
process advice in this whole effort.

Re-running under `-DCMAKE_BUILD_TYPE=Debug` immediately produced something four
sessions of Release measurement could not see:

```
MD, stock path, Debug interpreter, fails at tick 14 (the boot divergence window):

  Assertion failed: (sr_test(SR_S0) == 0 && sr_test(SR_S1) == 0),
    function alu_mac, file dsp_ops_alu.inl, line 490.
```

The MD firmware sets **scaling mode** (SR bits S0/S1) and executes a MAC. The
interpreter's `alu_mpy` (line 448) and `alu_mac` (line 490) both assert that
scaling mode is OFF — and two further asserts of the same condition are
**commented out** at lines 370 and 410, which suggests a history of hitting these
and silencing them. The engine's own unit suite (`dsp56kTestRunner`) passes clean
under Debug, so this combination is **not covered by any test**.

**Not yet established: whether this is a real defect or an over-strict leftover
assert.** The interpreter does implement scaling in the two places that matter
architecturally — `scale()` on accumulator transfer (`dsp.h:983`) and the rounder
position in `alu_rnd` (`dsp_ops_alu.inl:533`) — which mirrors what the JIT does in
`transferSaturation24/48` via `JitDspMode`. So MAC itself may legitimately not
need scaling handling. This needs a direct JIT-vs-interpreter arithmetic
comparison with S0/S1 set. We did not get that far.

Also under Debug: the MM halt reproduces at the **same** point, but names a
more precise location than the Release build's `INVALID PC ff0000` —
`Assertion failed: (0 && "invalid memory address"), function getOpcode,
file memory.cpp, line 232`.

**What this means for everything below.** The throughput numbers in Part 2 are a
Release-vs-Release comparison and stand. The *correctness* conclusions in Parts
1 and 3 were all drawn from assert-blind binaries and should be re-derived under
Debug before anyone builds on them. We are flagging this rather than quietly
re-writing, because the measurements are real and reproducible — it is the
confidence, not the content, that the Release build undermines.

---

## Part 1 — Engine issues, independent of the interpreter project

### 1.1 `DSP::exec()` instruction granularity is backwards (dead code)

`dsp56kEmu/dsp.h`, `DSP::exec()`:

```cpp
const auto& config = m_jit.getConfig();
if(!config.maxDoIterations || !sr_test_noCache(SR_LF))
{
    execInterpreter();       // one instruction
    return;
}
// reachable ONLY when maxDoIterations != 0 AND SR_LF is set:
if(!sr_test_noCache(SR_LF))  // <-- provably false; block is DEAD
{
    ... run up to maxInstructionsPerBlock instructions ...
    return;
}
// hardware-loop slice: runs up to maxInstructionsPerBlock instructions
```

The second block's comment says it exists to "match the JIT's granularity
outside hardware loops". It can never execute — `SR_LF` is provably set at that
point. **Net actual behaviour: 1 instruction OUTSIDE a hardware loop, and up to
`maxInstructionsPerBlock` (32) INSIDE one** — the inverse of the stated intent.

**Why it matters (measured).** Any host that advances a DSP until a condition
becomes true re-tests that condition only between `exec()` calls, so inside a
hardware loop it overshoots by up to 32 instructions. The DSP56303 bootstrap
loader's HRX poll is `brclr #0,x:<<$ffffc3,*` *inside* a `dor` hardware loop,
which is the worst case. Measured cost of one host word during the firmware
upload, with the caller's exit condition unchanged:

```
                      JIT      interpreter
cycles per host word   19             164
```

A trace of a single drain shows one `exec()` call, one PC (`14ff1b`), **145
cycles** — ~29 spin iterations executed after the word was already consumable.

Splitting each host word into pre-handover (publication → the DSP's read of HRX)
and post-handover (that read → the waiting loop returning), over an identical
250,125 words:

```
              JIT        interpreter
pre     2,225,029          1,251,191   <- interpreter is FASTER to hand over
post        2,690         34,941,417   <- 12,990x
postMax        10                140
```

So it is **not** latency — it is pure post-condition overshoot, and it accounted
for ~17% of that DSP's total machine time. Switching only that loop to
single-instruction stepping removed it (`postMax` 140 → 2).

**Suggested fix:** delete the dead block and decide the contract explicitly. We
would suggest keeping coarse `exec()` for bulk time-advance and offering a
single-instruction primitive for condition-closing loops (`execMinimalStep()`
already exists and does exactly this).

**Caveat, stated honestly:** several "granularity ruled out" results in our own
earlier notes were measured on a binary that did not do what its comments say.
Treat any prior granularity conclusion in this codebase with suspicion.

### 1.2 The interpreter had no PC guard (may already be fixed for you)

`DSP::execOp()` indexed `m_opcodeCache` with an unchecked PC and **called the
result**. The JIT has guarded this for years (`g_jitPcGuard` → `onInvalidPC`);
the interpreter had no equivalent, so a PC outside valid P memory is a wild read
and a host-process SIGSEGV with no diagnosis.

One compare on a hot path, branch never taken in normal operation. This matters
most on iOS, where the interpreter is the only engine and a garbage function
pointer is an instant kill with nothing to debug. It is what turned the failure
in 1.3 into a diagnosable halt with registers.

### 1.3 `onInvalidPC()` halts by sleeping — this affects the JIT path too

`dsp56kEmu/dsp.cpp`, after reporting an invalid PC:

```cpp
// halted: ... keep the thread alive so that the rest of the machine (and the
// user) can observe the state instead of getting a segfault. Sleep to not burn a core.
std::this_thread::sleep_for(std::chrono::milliseconds(1));
```

It sleeps 1 ms and **returns**, so the caller keeps calling it and the whole
machine crawls forever instead of failing. That is a sensible choice for
interactive debugging, but in a headless bench, a CI run, or a shipped plugin it
presents as a **silent hang rather than a fault**. We lost several long test
runs to this before spotting it in a profile (13,716 of 13,727 samples were in
`onInvalidPC` → `sleep_for`).

Unlike 1.1 and 1.2 this is **not interpreter-specific** — it is the shared halt
path. Suggest a context flag, or a halted-state return so the host can decide.

---

## Part 2 — Interpreter throughput (the number worth reusing)

Measured with the tree's own `mdBench` harness (headless realtime-factor
benchmark), Monomachine, 10 s of audio, M1 Mac mini:

```
                    sustained instr/s     realtime factor
JIT                       59.3M                1.172x
interpreter               28.2M               ~0.56x
```

**The interpreter runs at ~48% of JIT speed on this engine.** That ratio is
useful on its own as a screening test for "could synth X run interpreted on
device", without building an interpreter path at all:

> take the synth's JIT realtime factor, halve it, scale for the target device
> (an M4 iPad is ~1.6x an M1 on single core, and this emulation is effectively
> single-threaded). If the result clears ~1.5x, an interpreter port is plausible.

**Inferred, not measured:** a 2.1x JIT-to-interpreter ratio is unusually narrow
(5–20x is typical). That suggests much of the cost is in code *both* engines
share — peripherals, DMA, ESSI, the scheduler — rather than instruction
dispatch. If true, profiling that shared path would speed up **both** engines,
which would be worth more than interpreter tuning. We did not get to test this;
the one profile we attempted was invalid because the DSP had already halted.

### Why MD/MM were a bad test case for this

MD/MM run **two DSP56303s plus a full ColdFire MCU** interleaved on one thread.
`virusLib` (non-TI), `xtLib` and `mqLib` are single-DSP. So MD/MM are roughly
2–3x the emulation load of the others, and their failure to reach realtime under
the interpreter should **not** be read as a verdict on the interpreter generally.

---

## Part 3 — MD/MM interpreter status (for the fork author)

Not solved. MD has never booted under the interpreter — this is unimplemented
behaviour, not a regression; upstream has no issues on the interpreter and this
work is greenfield. There is no working baseline, so a "pristine upstream"
control is not meaningful.

**What moved.** Fixing the 1.1 overshoot took the mixer's host-command count at
a fixed tick from **0 to 665** (JIT: 1762), kept the mixer out of its error loop,
and got both DSPs into firmware. Prior sessions' collapse chain said the mixer
"never arms DMA channel 5" — that is no longer true: it arms at the same point in
the boot as the JIT (cycle 235,108,323 vs 235,583,526) and sustains it at 1/18th
the rate (804 arms vs 15,204). It then wedges.

**Two things we were wrong about, and one caveat:**

- Monomachine does **not** merely have a throughput problem. It halts with
  `INVALID PC ff0000` after **~12 seconds of ordinary audio rendering** in
  `mdBench` (at 605,667,784 instructions), not only in the three-phase
  state-restore test we had previously scoped it to. `ff0000` is the DSP56303
  on-chip bootstrap ROM, which this emulator does not map there.
- Scoring candidate fixes on a host-port stream-divergence index was misleading.
  The configuration that scored best on it is near-*worst* on boot progress,
  because the flag that improves it (`MD_HDI08_SLACK`) reinstates the very
  overshoot from 1.1. Score on boot progress, not stream index.
- We never completed a pristine-tree control run to fully rule our own
  instrumentation out of the MM halt. We believe it is pre-existing (all gates
  default off; the JIT build with identical changes benches clean) but it is
  **not proven**.

---

## Part 4 — Corrections to our own earlier claims

Recorded because they are in the commit history and someone may build on them.

- We claimed the ColdFire "never reaches `0x1000766`". **Not supported.** The
  instrument logs only at host-port accesses, so the evidence supports only
  "never performed a host-port access from that address". It may execute freely.
- We described a PC as where the MCU "lingers". That is call-site **interval**
  attribution (time between one host-port event and the next, anywhere), not
  instruction residency profiling.
- The DMA re-arm rate comparison (804 vs 15,204) conflates DSP service time with
  idle time awaiting the MCU's next request. Fewer arms may mean the MCU asked
  for less work, not that the DSP failed to serve. "Requests issued vs arms
  serviced" must be separated before calling it a receiver defect.

---

## Reproduction

```sh
ROM=elektron_sps1-1uw_os1.63.bin           # MD
MM=elektron_sfx6-60_os1.32b.bin            # MM

# throughput, both engines (build-interp configured with DSP56K_FORCE_INTERPRETER=1)
build-jit/source/elektron/md/mdLibTest/mdBench    $MM mm 10
build-interp/source/elektron/md/mdLibTest/mdBench $MM mm 10   # halts ~12s in

# per-host-word pre/post split (Part 1.1)
MD_WORDLAT=1 GEARMULATOR_MD_FIRMWARE_BIN=$ROM MD_TEST_SECONDS=2 \
  build-<engine>/source/elektron/md/mdLibTest/mdPanelReadinessFirmwareTest

# the overshoot fix
MD_DRAIN_MINSTEP=1 ...
```

A long run takes minutes of wall clock. Redirect to a file and grep the file —
piping a running test through `grep` has faked a hang here via block buffering.
Existing logs contain NULs, so use `grep -a`.
