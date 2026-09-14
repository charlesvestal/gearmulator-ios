# Profile-guided optimisation for the ESP interpreter

`je8086.profdata` is a merged clang profile for the interpreted ESP engine.
Building with it is worth **+45% serial / +50% pipelined**, bit-exact — more
than every hand optimisation in this series combined, from a build flag.

That is not a surprise in hindsight: the interpreter is a large switch in a hot
loop over a program the branch predictor can learn, which is precisely the shape
PGO exists to fix. It should have been tried first, not last.

## Rebuilding the profile

Regenerate whenever `esp.hpp`'s step loop changes materially; a stale profile
degrades quietly rather than failing.

    cmake -S . -B build-pgo-gen -DCMAKE_BUILD_TYPE=Release -G Ninja \
      -DCMAKE_CXX_FLAGS="-fprofile-generate=/tmp/pgodata" \
      -DCMAKE_EXE_LINKER_FLAGS="-fprofile-generate=/tmp/pgodata"
    cmake --build build-pgo-gen --target bench_je -j
    rm -rf /tmp/pgodata
    JE_NO_AUTO_PIPELINE=1 JE_ESP_INTERP=1 ./build-pgo-gen/bench_je dist/jp8000/roms
    xcrun llvm-profdata merge -output=pgo/je8086.profdata /tmp/pgodata/*.profraw

## Using it

    -DCMAKE_CXX_FLAGS="-fprofile-use=$PWD/pgo/je8086.profdata \
       -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled"

## It generalises

Trained on `bench_je` alone, then measured on scripts it never saw, with
byte-identical audio in every case:

| held-out script | baseline | PGO   | speedup |
|-----------------|----------|-------|---------|
| patch_sweep     | 22.72 s  | 17.17 s | 1.32x |
| chord_attack    |  9.74 s  |  6.70 s | 1.45x |
| dense_play      | 23.86 s  | 16.84 s | 1.42x |

A macOS/arm64 profile applies to the iOS/arm64 build: clang profiles key on
function names and counter indices, not on the target.

---

# Profile-guided optimisation for the DSP56300 interpreter

`dsp56k.profdata` is the equivalent for `dsp56kEmu`, used by
`scripts/build_ios_dsp56k.sh`. Worth **+17%** on the Virus TI.

iOS builds the DSP56300 synths with `DSP56K_FORCE_INTERPRETER=1` -- the JIT
needs an executable mapping iOS will not grant a non-entitled process -- so the
interpreter is the whole engine there, and the same reasoning as the ESP applies.

## Rebuilding the profile

    cmake -S libs/gearmulator -B build-pgo-gen -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DDSP56K_FORCE_INTERPRETER=1 \
      -DCMAKE_CXX_FLAGS="-fprofile-generate=/tmp/pgo56k" \
      -DCMAKE_EXE_LINKER_FLAGS="-fprofile-generate=/tmp/pgo56k" \
      -Dgearmulator_SYNTH_OSIRUS=on -Dgearmulator_SYNTH_OSTIRUS=on \
      -Dgearmulator_SYNTH_VAVRA=on -Dgearmulator_SYNTH_XENIA=on
    cmake --build build-pgo-gen --target dsp56kBench -j

Train on all four, and give each run its own LLVM_PROFILE_FILE -- one binary
(`dsp56kBench_virus`) serves both the ABC and the TI, so without distinct paths
the second run OVERWRITES the first and the profile is blind to one of them:

    rm -rf /tmp/pgo56k && mkdir -p /tmp/pgo56k
    LLVM_PROFILE_FILE=/tmp/pgo56k/abc.profraw ... dsp56kBench_virus virus <rom> 3 4 100 1
    LLVM_PROFILE_FILE=/tmp/pgo56k/ti.profraw  ... dsp56kBench_virus virusTI firmware.bin 3 4 100 1
    LLVM_PROFILE_FILE=/tmp/pgo56k/mq.profraw  ... dsp56kBench_mq mq "" 3 4 100 1
    LLVM_PROFILE_FILE=/tmp/pgo56k/xt.profraw  ... dsp56kBench_xt xt "" 3 4 100 1
    xcrun llvm-profdata merge -output=pgo/dsp56k.profdata /tmp/pgo56k/*.profraw

## Bit-exactness

Identical audio on both synths where the question can be ASKED:

| synth  | self-reproducible | PGO vs not |
|--------|-------------------|------------|
| ABC    | yes               | identical  |
| TI     | yes               | identical  |
| microQ | **no** -- 2 hashes / 3 runs | unmeasurable |
| XT     | **no** -- 3 hashes / 3 runs | unmeasurable |

The Waldorfs are nondeterministic run to run against a FIXED binary -- a 68k
and one to three DSPs on loosely synchronised threads -- so no bit-exactness
claim about them is measurable with this harness. Check self-reproducibility
before reading any hash difference as a regression.

## Measure back to back or not at all

The iPad's sustained rate is far below its cool rate. The same non-PGO binary
measured **1.59x** early in a session and **0.999x** after ~40 minutes of
benchmarking -- 37% decay, on a device with no fan. A PGO build measured
against a baseline taken earlier reads as SLOWER than it is; that happened here
and inverted the first conclusion. Alternate the two binaries within one
session, as `bitexact.sh` does for hashes.
