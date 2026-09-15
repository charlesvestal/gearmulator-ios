# Machinedrum and Monomachine on iOS

Status: **the emulator is fast enough; a livelock in the DSP boot handshake is
what stops it.** Measured 2026-09-15 on an M5 iPad Pro, interpreted, no JIT.

MD/MM are not part of this tree. They live in
[joelanders/gearmulator-md-mm](https://github.com/joelanders/gearmulator-md-mm),
a fork that sits on the pre-reorg upstream layout (flat `source/`, no
`source/framework` or codename directories) and has no iOS support. Everything
below was done in a scratch clone of that fork; none of it is committed here.

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

**1.8-2.2x real time while it is executing**, interpreted. Then the mixer DSP
stops -- exactly zero instructions per second -- while the producer runs flat
out at ~200M instr/s indefinitely. The mixer is the master clock, so audio time
never advances again. The whole stall lives inside a single `process()` call.

Reproduced identically on an idle M1 desktop (producer ~95M instr/s, mixer 0),
so it is neither machine load nor a device limit.

## Why it is a livelock and not a slow interpreter

Instruction counts, not timings, settle this. For the same emulated second:

| build | mixer | producer | outcome |
|---|---|---|---|
| JIT | 68.5M | 75.1M | completes |
| interpreter | 0 | 8.5 billion and counting | never completes |

About 100x more emulated work for identical audio. The two builds are therefore
**not emulating the same thing** -- this is a divergence in emulated timing, not
a wall-clock difference.

The likely mechanism is `fastForward`, which exists only in the JIT
(`jitops_jmp.cpp`, via `esaiFrameSyncSpinloopBra`/`Jmp` on the `_qq` addressing
forms). It does not merely save time: it advances the instruction and cycle
counters without executing, so a DSP spinning on a frame sync reaches it in a
handful of emulated instructions instead of millions. Remove it and the
cycle-exact transport can settle into a spin the JIT never experiences. Every
stack sample of the stall sits in `op_Dor_S` -> `op_Brclr_pp` ->
`HDI08::readStatusRegister`, reached through `Hdi08::read8` ->
`schedCatchUpDsp`: the MCU polling the host port for data while the DSP it
catches up is spinning for the MCU to write.

Note the `_pp` there. The JIT's skip only covers `_qq`, so it does **not** skip
this particular spin, and a simple "port `fastForward` to the interpreter" is
not obviously the whole fix.

## What this means for a port

Not a CPU problem. An M5 iPad sustains ~200M DSP instructions/sec per DSP
against the ~80M/s each emulated DSP actually retires, so there is roughly 2x
headroom even with everything on one thread. The work is:

1. Find and fix the boot livelock. This is the blocker, and it is a correctness
   bug in interpreter mode rather than a performance ceiling.
2. Only then ask about steady-state cost, which the numbers above suggest is
   comfortable rather than marginal.
3. Separately, the fork would need our iOS patch set (AUv3 bus layout, realtime
   thread policy, editor sizing) replayed onto its older tree -- or the elektron
   directory moved onto ours. The former is smaller: ~76 commits, ~4.8k lines.

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
