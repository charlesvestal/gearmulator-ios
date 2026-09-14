# gearmulator-ios

An **unofficial** iOS build harness for
[gearmulator](https://github.com/dsp56300/gearmulator) — The Usual Suspects'
DSP56300 and H8S synth emulators — producing a **Standalone app and an AUv3**
for iPad.

Not affiliated with or endorsed by The Usual Suspects. All credit for the
emulators belongs to them; this repo only builds and packages their work for a
platform they do not currently target.

The engine itself is not here. `libs/gearmulator` is a submodule of a fork
carrying the iOS-specific fixes (AUv3 bus layout, the realtime thread policy,
editor sizing, factory bank loading, application icons); this repo is the build,
packaging and asset side. Those fixes are candidates for upstreaming rather than
a permanent divergence.

**Status: personal/experimental.** It runs on an M-series iPad and is not a
product. See Known issues below before investing time in it.

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

**No ROMs, firmware or factory banks are included, and none will be.** These are
copyrighted by their respective manufacturers. You are expected to own the
hardware and to dump or otherwise lawfully obtain its firmware yourself; what is
lawful is your responsibility and varies by jurisdiction. Do not open issues
asking where to get them.

Nothing here ships them. Drop the files a synth needs into
`roms-ios/<synth>/` (gitignored) and they are copied into the app, the embedded
.appex and the standalone .appex, which are then re-signed — adding files to a
signed bundle invalidates its signature, so the re-sign is inside-out.

## The JIT is compiled out

iOS will not map an executable page to a non-entitled process, so asmjit cannot
be used at all; every DSP56300 instruction runs through the interpreter
(`-DDSP56K_FORCE_INTERPRETER=1`). This is not a tuning choice — a JIT build fails
at runtime. `pgo/` holds profiles that buy back part of the cost; see
`pgo/README.md`, and `docs/IOS_AUV3.md` for measured per-synth throughput and
which devices these actually run on.

## Licence

GPLv3, the same licence as gearmulator, whose source this builds and links.
See `LICENSE.md`.
