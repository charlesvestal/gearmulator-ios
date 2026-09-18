# Interpreter DO-loop investigation — 2026-09-18

Work is in the active sibling checkout `../md-interp-work/mdmm/source/dsp56300`,
not this repository's older `libs/gearmulator` copy. Existing uncommitted changes
were preserved. Nothing has been pushed.

An isolated [session patch](../patches/md-do-loop-2026-09-18.patch) contains only
these changes, excluding the pre-existing cycle-accounting test edits. Its
reverse-apply check against the active checkout passed.

## Confirmed defect

The bounded interpreter epilogue compared `pcCurrentInstruction == LA`.
LA is the address of the **last instruction word**, not necessarily the opcode.
A two-word instruction ending a DO loop starts at LA-1. The old check skips both
loop-back and loop-frame removal. Subsequent RTS can then consume a loop frame
instead of the intended subroutine return frame.

The correction checks `pcCurrentInstruction + m_currentOpLen == LA + 1`, while
retaining `reg.pc == LA + 1`. The latter alone is insufficient: an RTI from
elsewhere can return to LA+1 without executing the loop's final instruction.

Reference: [DSP56300 Family Manual, Rev. 5, DO instruction, Note 1](https://www.nxp.com/docs/en/reference-manual/DSP56300FM.pdf).
The note explicitly discusses two-word instructions at the loop end.

A synthetic DO loop ending in a two-word immediate MOVE failed before the
epilogue change. macOS crash report located the failure in
`InterpreterUnitTests::testBoundedDoTwoWordEnd`, at the expected final-PC check.
With the change, the full Debug interpreter unit suite exits 0.

Extended tests, also passing in the full suite, cover:

- Individual loop iterations and the subsequent RTS.
- Nested loops with two-word final instructions, exact executed instruction
  count, restored SP, and cleared LF.
- Scheduler-facing `exec()` at slices 1, 2, 4, 8, and 16.
- RTI from elsewhere into LA+1 without spurious loop processing.

This does not establish full-machine slice invariance. All the previously
tested nonzero slice sizes use the same defective epilogue, so failure at every
size did not rule out this epilogue as the cause.

## ARM64 Debug initialization blocker

Reproduced asmjit's `InvalidImmediate: add x20, x22, 17944` during DSP
construction, even in a forced-interpreter build. The JIT object still generates
trampolines during construction. Debug trace buffers put the DSP register block
outside the immediate range accepted by that ADD encoding.

Both trampoline sites now use the existing `lea_` helper, which materializes
large offsets in a register. This allowed the ARM64 Debug runner and firmware
bench to initialize. The x86_64 alternative could not run on this machine
(`Bad CPU type in executable`).

## Firmware validation

Build: existing `build-dbg-interp`, Debug, `DSP56K_FORCE_INTERPRETER=1`, ARM64
slice of the universal binaries. No timing overrides.

Monomachine command:

```sh
build-dbg-interp/source/elektron/md/mdLibTest/mdBench \
  ../artifacts/mdrom/elektron_sfx6-60_os1.32b.bin mm 10 256
```

Result: **exit 0**, eight seconds boot plus ten seconds render, peak **0.4128**,
no illegal-instruction or invalid-PC halt. The previous halt occurred just
after the eight-second boot. Recorded JIT control peak: 0.4134. This comparison
is not a claim of sample-identical audio.

Machinedrum command:

```sh
MD_XIOREAD=1 \
GEARMULATOR_MD_FIRMWARE_BIN=../artifacts/mdrom/elektron_sps1-1uw_os1.63.bin \
  build-dbg-interp/source/elektron/md/mdLibTest/trigPressFirmwareTest \
  md --trig 1 --hold
```

Result: **exit 0**, default/out-of-record Trigger1 press, two-second hold,
release and settle. Press peak **0.204363**, held peak **0.223144**. Final mixer
instruction count **2,229,951,961**, beyond the old failure at **2,102,488,972**.
Both DSPs continued retiring instructions. No illegal-instruction, invalid-PC,
`MD_XIOREAD`, or `MD_XIOWRITE` reports.

Scope: this run selected Trigger1, not all 16 keys (the test's generic PASS
message says "every trig key" even when `--trig` selects one). These are headless
Debug results; no on-device validation or throughput work was performed.

Logs:

- `/tmp/md-do-test-red.log` — pre-fix regression run.
- `/tmp/md-do-test-final.log` — full final Debug suite, exit 0.
- `/tmp/mm-do-fix-debug.log` — completed MM firmware run.
- `/tmp/md-trig-do-fix-debug.log` — completed MD Trigger1 validation.

## Read-side routing audit

Added opt-in Debug `MD_XIOREAD=1` diagnostics at entry to `DSP::memRead`, before
AAR translation. They identify ordinary X/Y memory reads whose original address
belongs to peripheral space. Output is bounded to 24 reports and existing read
behavior is preserved. Existing `Memory::get` Debug assertions remain active.

The Rn+displacement routing sites have not been changed. Firmware exercise of
those paths is a separate question from the confirmed DO-loop defect.
No bypass was observed in the MD run above. The MM run preceded addition of
the opt-in diagnostic; it retained the existing Debug memory assertions.
