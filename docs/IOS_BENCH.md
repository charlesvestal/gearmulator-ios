# Benchmarking on the device

`dsp56kBench` measures one number per synth: the interpreter's real-time
factor. Until now it only ran on the host, where it was built to train PGO
profiles (`pgo/README.md`). This describes running it on an actual iPhone or
iPad, which is the only place the answer is authoritative -- iOS has no JIT, so
a Mac figure is a proxy for a machine that is not the target.

## Why a host measurement is not enough

A desktop Release build of `dsp56kBench_virus` reads **0.95x** at 4 voices on an
M1. The iPhone 15 Pro reads 0.96x for the same synth. Those agree, and for a
while that looked like enough to trust the proxy for everything else.

It is not, and the reason is worth stating plainly: the Mac figure was measured
with the JIT compiled out but with none of the other differences -- PGO, thread
realtime parameters, core mix, thermal behaviour -- and nothing about that
agreement generalises to another synth. Measure on the device.

## The three things that make it work

**It has to be an app.** A binary only reaches a device inside a signed `.app`.
The bench targets set `MACOSX_BUNDLE` on iOS, take the signing team from
`DEVELOPMENT_TEAM`, and copy the ROMs in as bundle resources.

**It has to become a UIApplication.** A bundle whose `main()` only computes is
SIGKILLed once it stops answering the system, about 20 seconds in. That is not
long enough to boot a synth's firmware, so every run died mid-measurement and
reported a single progress line. `iosmain.mm` makes the bench a real
`UIApplication` and runs the work on a background queue; the main thread stays
responsive on its run loop and the emulation takes as long as it needs. Without
this the ceiling is roughly one emulated second.

**Its output has to go to a file.** Several loggers in this tree write straight
to `stdout`/`stderr` -- `baseLib::logging` to stdout, `mc68k::logToConsole` to
stderr, with no mute hook -- and pushing per-bus-access chatter through the
device console is itself slow enough to distort what is being measured. The
bench redirects stdout into its container and drops stderr.

There is no argv: `devicectl` launches by bundle identifier, so each target
compiles in its synth name (`BENCH_IOS_SYNTH`) and a default argument set, and
`chdir`s into `Resources` so the existing ROM discovery finds the firmware.

## Running it

Build one bundle per synth, pointing `DSP56KBENCH_IOS_ROMS` at a directory whose
contents are copied into the app:

```bash
cmake -S libs/gearmulator -B build-ios-bench-device -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_CXX_FLAGS="-fprofile-use=$PWD/pgo/dsp56k.profdata -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled" \
  -DDSP56K_FORCE_INTERPRETER=1 \
  -DDSP56KBENCH_IOS_ROMS=$PWD/roms-ios/osirus \
  -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=XXXXXXXXXX \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_STYLE=Automatic \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=YES \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="Apple Development" \
  -Dgearmulator_BUILD_JUCEPLUGIN=off

cmake --build build-ios-bench-device --config Release --target dsp56kBench_virus
```

Use the same PGO flags the shipping build uses, or the number describes a build
nobody ships.

Install, run, and collect:

```bash
DEV=$(xcrun devicectl list devices | awk '/iPad Pro/{print $3}')
APP=build-ios-bench-device/source/framework/tools/dsp56kBench/Release-iphoneos/dsp56kBench_virus.app

xcrun devicectl device install app --device $DEV "$APP"
xcrun devicectl device process launch --device $DEV --console com.charlesvestal.dsp56kBench_virus

xcrun devicectl device copy from --device $DEV \
  --domain-type appDataContainer --domain-identifier com.charlesvestal.dsp56kBench_virus \
  --source Documents/dsp56kBench.log --destination ./dsp56kBench.log
```

The log can be copied off **while the run is still going**, which is how to
watch a long or stuck run progress.

## Reading the result, and not fooling yourself

Three ways a figure from this tool can be wrong, all of which produced
confidently-reported nonsense before being caught:

**Machine load.** The single largest source of error, and it applies to the host
runs used for PGO training as much as to anything else. The same binary with the
same arguments read **0.101x** on a busy Mac and **0.949x** idle -- a 9.4x swing
that looks exactly like a catastrophic finding. `dsp56kBench.cpp` already takes
the fastest of several passes to blunt this; it is not enough. Do not run a
benchmark while a build, or another benchmark, is running.

**Buffered pipes.** `binary | grep ...` block-buffers, so a long run appears to
produce nothing and looks hung when it is working fine. Redirect to a file and
filter afterwards.

**The watchdog.** If a device run ends after one progress line, check the
console for `App terminated due to signal 9` before concluding the engine
stalled.

When a run really is stuck rather than slow, timings cannot tell you why,
because a stall can live inside a single `process()` call where no
instrumentation on the render loop ever fires. Sample
`dsp56k::DSP::getInstructionCounter()` from a separate thread instead: it
separates "executing far more instructions" from "executing at a collapsed
rate", and it is the only thing that identified the MD/MM boot livelock
(see `MD_MM_IOS.md`).

## Measured

M5 iPad Pro, interpreted, arm64, PGO:

| synth | result |
|---|---|
| Machinedrum | 2.416x measured throughput after a 4.64 s bench warmup; firmware panel boot still fails in interpreter mode; see `MD_MM_IOS.md` |
| Monomachine | 0.71-0.79x with ThinLTO and MD/MM-trained PGO; below real time. Trigs produce samples in the device app, but no audible output was reported |
| Osirus (Virus C) | 0.431x at 4 voices -- but see the caveat below |

**A synth that runs its DSPs on their own threads does not measure honestly
here.** Osirus reads 0.431x on an M5 iPad and 0.949x running the same bench on
an M1 desktop, which is backwards, and it contradicts the plugin being
comfortable on that iPad. virusLib puts its DSP on a realtime-constrained
thread (`computation=1333us, constraint=2666us`) sized for an audio callback;
free-running in a bench with no callback to pace it, that budget caps
throughput. Treat device figures for threaded synths as a floor until the
bench either drives them through `synthLib::Plugin` or matches the plugin's
thread policy.

Machinedrum does not have this problem: `md::Hardware` advances its MCU and
both DSPs on the calling thread and spawns nothing, which is why its figure is
directly comparable to the desktop's.

The earlier 1.80-2.17x Machinedrum result sampled only the phase before the
interpreter livelocked and was not an end-to-end throughput result. With the
loop fix, ThinLTO, and a profile trained on both MD and MM firmware, MD renders
five seconds of audio in 2.07 seconds after its bench warmup; this does not
show that its firmware reached a usable screen. MM's bench produced nonzero
audio, and iPad trigs also produce nonzero main-bus samples, but no audible
output was reported. MM remains about 21-29% below real time. A Time Profiler capture
shows costs spread across the scheduler, opcode dispatch, peripherals, parallel
instructions, multiply, and DMA; there is no single stuck scheduler path.
