#!/usr/bin/env bash
#
# Build a DSP56300 gearmulator synth for iOS (AUv3 + Standalone host app; the
# .appex is embedded in the app).
#
#   scripts/build_ios_dsp56k.sh osirus                          # simulator
#   DEVELOPMENT_TEAM=J4722B5MJW scripts/build_ios_dsp56k.sh osirus device
#
# THE JIT IS COMPILED OUT (-DDSP56K_FORCE_INTERPRETER=1). iOS will not map an
# executable page to a non-entitled process, so asmjit cannot be used at all --
# this is not a tuning choice, a JIT build would fail at runtime. Every DSP56300
# instruction therefore runs through DSP::execInterpreter().
#
# Measured cost of that, Virus C on an idle M1 P-core, 5 s render, best of 3
# (dsp56kBench_virus, JIT build vs interpreter build):
#
#   4 voices, 100% DSP clock ... 0.96x real-time
#   4 voices,  80% DSP clock ... 1.11x real-time
#
# so a stock-clock Virus does NOT reach real time interpreted and one step of
# underclocking (DSP/Audio settings page, a shipped feature) clears it. The
# audio is bit-identical at every clock down to 40% at four voices.
#
# PGO: pgo/dsp56k.profdata, trained across all four synths. Worth +17% on the
# Virus TI, measured back-to-back on an iPad Pro M5 (0.999x -> 1.17x), and
# bit-exact on both synths where bit-exactness is measurable at all -- the ABC
# and the TI reproduce against themselves, microQ and XT do not (2 and 3
# distinct hashes over 3 runs of one binary), so no claim is possible there.
#
# +17% rather than the ESP's +45% because this interpreter was already
# optimised. It still matters more than it looks: the iPad's SUSTAINED rate is
# far below its cool rate -- the same binary measured 1.59x cool and 0.999x
# after 40 minutes of benchmarking -- so +17% is the difference between sitting
# on the 1.0x threshold and sitting above it.
#
# A macOS/arm64 profile applies to an iOS/arm64 build: clang profiles key on
# function names and counter indices, not on the target. See pgo/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

SYNTH="${1:-osirus}"
MODE="${2:-simulator}"

# synth key -> cmake flag, product name, default rom dir
case "$SYNTH" in
  osirus)      SYNTH_FLAG=OSIRUS;      PRODUCT="Osirus";      TARGET=osirusJucePlugin_All ;;
  ostirus)     SYNTH_FLAG=OSTIRUS;     PRODUCT="OsTIrus";     TARGET=osTIrusJucePlugin_All ;;
  vavra)       SYNTH_FLAG=VAVRA;       PRODUCT="Vavra";       TARGET=mqJucePlugin_All ;;
  xenia)       SYNTH_FLAG=XENIA;       PRODUCT="Xenia";       TARGET=xtJucePlugin_All ;;
  nodalred2x)  SYNTH_FLAG=NODALRED2X;  PRODUCT="NodalRed2x";  TARGET=n2xJucePlugin_All ;;
  *) echo "usage: $0 <osirus|ostirus|vavra|xenia|nodalred2x> [simulator|device]" >&2; exit 1 ;;
esac

ROMS="${ROMS:-roms-ios/$SYNTH}"

BUILD_DIR="build-ios-$SYNTH"
[[ "$MODE" == "device" ]] && BUILD_DIR="$BUILD_DIR-device"
EXTRA_BUILD_ARGS=()

REPO="$(pwd)"
PGO_FLAGS=""
if [[ -f "$REPO/pgo/dsp56k.profdata" ]]; then
  PGO_FLAGS="-fprofile-use=$REPO/pgo/dsp56k.profdata -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled"
  echo "==> Using PGO profile pgo/dsp56k.profdata"
else
  echo "==> WARNING: no pgo/dsp56k.profdata -- building WITHOUT PGO, which costs ~17%"
fi

COMMON_ARGS=(
  -DCMAKE_CXX_FLAGS="$PGO_FLAGS"
  -S libs/gearmulator
  -B "$BUILD_DIR"
  -G Xcode
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DDSP56K_FORCE_INTERPRETER=1
  -Dgearmulator_SYNTH_OSIRUS=off
  -Dgearmulator_SYNTH_OSTIRUS=off
  -Dgearmulator_SYNTH_VAVRA=off
  -Dgearmulator_SYNTH_XENIA=off
  -Dgearmulator_SYNTH_NODALRED2X=off
  -Dgearmulator_SYNTH_JE8086=off
  "-Dgearmulator_SYNTH_${SYNTH_FLAG}=on"
)

if [[ "$MODE" == "device" ]]; then
  : "${DEVELOPMENT_TEAM:?device builds need DEVELOPMENT_TEAM set (Apple dev team ID)}"
  echo "==> Configuring $PRODUCT iOS device build (team $DEVELOPMENT_TEAM, automatic signing)"
  cmake "${COMMON_ARGS[@]}" \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_STYLE=Automatic \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=YES \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=YES \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="Apple Development"
  SDK=iphoneos
  EXTRA_BUILD_ARGS=(-allowProvisioningUpdates)
else
  echo "==> Configuring $PRODUCT iOS simulator build (no signing)"
  cmake "${COMMON_ARGS[@]}" \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  SDK=iphonesimulator
fi

echo "==> Building (config Release, sdk $SDK)"
cmake --build "$BUILD_DIR" --config Release --target "$TARGET" \
  -- -sdk "$SDK" ${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"}

OUT="libs/gearmulator/bin/plugins-ios/Release"

# RomLoader searches the directory the loaded binary sits in, which for an iOS
# bundle is the bundle root. The AUv3 a host loads is the one EMBEDDED in the
# app (PlugIns/), so it needs its own copy; adding files to a signed bundle
# invalidates the signature, so re-sign inside-out afterwards.
APP="$OUT/Standalone/$PRODUCT.app"
if compgen -G "$ROMS/*" > /dev/null 2>&1; then
  copied=0
  for bundle in "$OUT/AUv3/$PRODUCT.appex" "$APP" "$APP/PlugIns/$PRODUCT.appex"; do
    [[ -d "$bundle" ]] || continue
    # every loader matches case-insensitively on extension and filters by SIZE
    # .syx as well as .mid: factory BANK dumps ship in either container and the
    # patch managers scan both (NodalRed2x's Factory Program Library is .syx).
    find "$ROMS" -maxdepth 1 -type f \( -iname '*.bin' -o -iname '*.mid' -o -iname '*.syx' \) \
      -exec cp {} "$bundle/" \; && copied=1
  done
  if [[ $copied == 1 ]]; then
    echo "==> ROMs from $ROMS copied into the app, the embedded .appex and the standalone .appex"
  fi

  if [[ "$MODE" == "device" ]]; then
    IDENTITY="${CODESIGN_IDENTITY:-}"
    if [[ -z "$IDENTITY" ]]; then
      while read -r _n sha rest; do
        [[ "$rest" == *"Apple Development"* ]] || continue
        ou=$(security find-certificate -c "${rest//\"/}" -p 2>/dev/null \
             | openssl x509 -noout -subject 2>/dev/null | tr ',' '\n' | grep -o 'OU=.*' | head -1)
        [[ "$ou" == "OU=$DEVELOPMENT_TEAM" ]] && IDENTITY="$sha" && break
      done < <(security find-identity -v -p codesigning)
    fi
    : "${IDENTITY:?no Apple Development identity found for team $DEVELOPMENT_TEAM}"
    for bundle in "$APP/PlugIns/$PRODUCT.appex" "$APP" "$OUT/AUv3/$PRODUCT.appex"; do
      [[ -d "$bundle" ]] || continue
      codesign --force --preserve-metadata=entitlements,identifier,flags \
               --sign "$IDENTITY" "$bundle" >/dev/null
    done
    echo "==> Re-signed (ROMs added after the build's own signing step)"
  fi
else
  echo "==> WARNING: no ROMs in $ROMS -- the plugin will boot silent"
  echo "    expected there: osirus/vavra/nodalred2x 512K .bin | ostirus 6-9M .bin"
  echo "                    xenia 256K .bin (or two 128K halves) | osirus also 500-600K .mid"
fi

echo "==> Done. Artefacts under $OUT/"
