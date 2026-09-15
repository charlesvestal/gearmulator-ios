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

**Status: personal/experimental**, not a product. See Compatibility below, and
`docs/IOS_AUV3.md` for the measurements and the open problems.

| Product | Hardware |
|---|---|
| Osirus | Access Virus A/B/C |
| OsTIrus | Access Virus TI/TI2/Snow |
| Vavra | Waldorf microQ |
| Xenia | Waldorf Microwave II/XT |
| NodalRed2x | Clavia Nord Lead/Rack 2x |
| JE-8086 | Roland JP-8000 |

## Compatibility

The JIT cannot be used on iOS at all (see below), so everything runs through the
interpreter and CPU is the binding constraint. What decides it is **how many
DSPs a synth emulates**, not how fast the chip is.

| | iPad Pro M5 | iPhone 15 Pro (A17 Pro) |
|---|---|---|
| | 3-4P + 6E cores | 2P + 4E cores |
| Osirus (1 DSP) | works | plays, **breaks up** |
| OsTIrus (1 DSP) | works | plays -- heaviest of the Viruses, expect to underclock |
| Vavra (1 DSP) | works | plays |
| Xenia (3 DSPs) | works | plays, **breaks up** |
| NodalRed2x (2 DSPs) | works | **no sound at all** |
| JE-8086 (H8S + ESP) | works | plays |

Measured 2026-09-15, every row tested rather than inferred. On the phone most of
these PLAY but break up under load; they are usable rather than clean, and
underclocking is what buys the margin back. DSP count is a rough guide and no
more -- Xenia emulates three and still makes sound, so what matters is the total
emulated work a synth demands, not how it is divided.

OsTIrus is the tightest of the Viruses -- the TI is a heavier model than the ABC
(1.60x against Osirus's 2.06x on the M5) -- so it is the most likely to need a
step down, and it has the control.

NodalRed2x is the one genuine failure: not marginal, about 2x
short: each of its two DSPs wants ~95 MIPS and gets 36-48, so the ESAI transmits
nothing rather than glitching. Underclocking does not help it -- on that device
the ESAI clock sets the output rate, so a lower clock means MORE emulated work
per second of audio (0.91x -> 0.44x at 50%), which is why the synth declines to
offer the control.

On the synths that do offer it, underclocking is the lever: one step down takes a
Virus from 0.96x to 1.11x at 4 voices. It lives in the DSP/Audio settings page,
reached by long-pressing the panel (touch has no right click) and enabling
advanced options.

Earlier notes here said no iPhone worked at all. That predated a fix to the
realtime thread policy and is wrong; see `docs/IOS_AUV3.md` for the measurements
and for what an M1/M2 iPad is expected to do.

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
