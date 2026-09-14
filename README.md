# gearmulator-ios

iOS build harness for [gearmulator](https://github.com/dsp56300/gearmulator) —
The Usual Suspects' DSP56300 and H8S synth emulators — producing a **Standalone
app and an AUv3** for iPhone/iPad.

The engine itself is not here. `libs/gearmulator` is a submodule of the fork
carrying the iOS fixes; this repo is the build, packaging and asset side.

| Product | Hardware |
|---|---|
| Osirus | Access Virus A/B/C |
| OsTIrus | Access Virus TI/TI2/Snow |
| Vavra | Waldorf microQ |
| Xenia | Waldorf Microwave II/XT |
| NodalRed2x | Clavia Nord Lead/Rack 2x |
| JE-8086 | Roland JP-8000 |

## Build

```bash
DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build_ios_dsp56k.sh <synth> device
DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build_ios.sh device          # JE-8086
```

`<synth>` is one of `osirus ostirus vavra xenia nodalred2x`. Omit `device` for
the simulator. Artefacts land in `libs/gearmulator/bin/plugins-ios/Release/`;
the AUv3 a host loads is the one embedded in the app's `PlugIns/`.

## ROMs and factory banks

Not distributable, so nothing here ships them. Drop the files a synth needs into
`roms-ios/<synth>/` (gitignored) and they are copied into the app, the embedded
.appex and the standalone .appex, which are then re-signed — adding files to a
signed bundle invalidates its signature, so the re-sign is inside-out.

Loaders match on extension (`.bin`, `.mid`, `.syx`) and filter by SIZE, so a
folder can hold a firmware ROM and a factory bank together without either being
mistaken for the other.

Waldorf's Microwave factory bank is a raw 64 KB image with no sysex in it at all
and cannot simply be renamed — run `scripts/mw2_bank_to_sysex.py` to wrap its 256
records into XT Single dumps first.

## The JIT is compiled out

iOS will not map an executable page to a non-entitled process, so asmjit cannot
be used at all; every DSP56300 instruction runs through the interpreter
(`-DDSP56K_FORCE_INTERPRETER=1`). This is not a tuning choice — a JIT build fails
at runtime. `pgo/` holds profiles that buy back part of the cost; see
`pgo/README.md`, and `docs/IOS_AUV3.md` for measured per-synth throughput and
which devices these actually run on.

## Known issues

- **AUv3 icons do not appear in hosts** (AUM, GarageBand) although the home
  screen icons are correct. The bundles were compared against a working AUv3 on
  the same device and match on packaging, asset catalogs, plist keys, signing,
  install path and component version. Unexplained; there is no public API for
  how a host resolves an audio unit's icon.
- **JE-8086 is unvalidated.** It builds, boots its ROMs and runs, but reports
  `limited requested latency ... audio will be out of sync` and its output has
  never been checked.
- The realtime-window fix is confirmed on NodalRed2x only; the other synths
  carry it but have not been re-tested under host UI load.

## History

Extracted from the `ios-auv3` branch of `schwung-je8086`, which had accumulated
this work alongside unrelated JP-8000 changes. Started fresh rather than carrying
that entangled history.
