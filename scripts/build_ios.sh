#!/usr/bin/env bash
#
# Build JE-8086 for iOS (AUv3 + Standalone host app; the .appex is embedded).
#
#   scripts/build_ios.sh                                  # simulator, no signing
#   DEVELOPMENT_TEAM=<YOUR_TEAM_ID> scripts/build_ios.sh device
#
# The ESP cores run INTERPRETED here: iOS will not map an executable page, so
# the asmjit emitter is compiled out (gearmulator_JE_NO_JIT, on by default for
# iOS) and ESP::step_cores() runs instead. That costs ~15x, which is why the
# ASIC pipeline (dspThreads > 1) is not optional on this platform.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-simulator}"
BUILD_DIR="build-ios"
[[ "$MODE" == "device" ]] && BUILD_DIR="build-ios-device"
EXTRA_BUILD_ARGS=()

# Profile-guided optimisation for the interpreted ESP. Worth +45% serial and
# +50% PIPELINED, bit-exact, which on iOS is the difference between one instance
# and two -- the interpreter is a big switch in a hot loop, exactly PGO's shape.
# A macOS/arm64 profile applies to an iOS/arm64 build: clang profiles key on
# function names and counter indices, not on the target. See pgo/README.md.
REPO="$(pwd)"
PGO_FLAGS=""
if [[ -f "$REPO/pgo/je8086.profdata" ]]; then
  PGO_FLAGS="-fprofile-use=$REPO/pgo/je8086.profdata -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled"
  echo "==> Using PGO profile pgo/je8086.profdata"
else
  echo "==> WARNING: no pgo/je8086.profdata -- building WITHOUT PGO, which costs ~50% of the pipelined throughput"
fi

COMMON_ARGS=(
  -DCMAKE_CXX_FLAGS="$PGO_FLAGS"
  -S libs/gearmulator
  -B "$BUILD_DIR"
  -G Xcode
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -Dgearmulator_SYNTH_OSIRUS=off
  -Dgearmulator_SYNTH_OSTIRUS=off
  -Dgearmulator_SYNTH_VAVRA=off
  -Dgearmulator_SYNTH_XENIA=off
  -Dgearmulator_SYNTH_NODALRED2X=off
  -Dgearmulator_SYNTH_JE8086=on
  # 88Emu arrived with the upstream merge and defaults ON. This script builds the
  # JE-8086 only, and with its own PGO profile -- CMAKE_CXX_FLAGS is tree-wide, so
  # anything else built here would silently get the ESP profile applied to it.
  -Dgearmulator_SYNTH_88EMU=off
)

if [[ "$MODE" == "device" ]]; then
  : "${DEVELOPMENT_TEAM:?device builds need DEVELOPMENT_TEAM set (Apple dev team ID)}"
  echo "==> Configuring iOS device build (team $DEVELOPMENT_TEAM, automatic signing)"
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
  echo "==> Configuring iOS simulator build (no signing)"
  cmake "${COMMON_ARGS[@]}" \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  SDK=iphonesimulator
fi

echo "==> Building (config Release, sdk $SDK)"
cmake --build "$BUILD_DIR" --config Release --target jeJucePlugin_All \
  -- -sdk "$SDK" ${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"}

OUT="libs/gearmulator/bin/plugins-ios/Release"

# The engine needs the eight JP-8000 firmware .mid files. RomLoader searches the
# directory the loaded binary sits in, which for an iOS bundle is the bundle
# root. The AUv3 a host loads is the one EMBEDDED in the app (PlugIns/), so it
# needs its own copy; adding files to a signed bundle invalidates the signature,
# so re-sign inside-out afterwards or the install is rejected.
# Same convention as build_ios_dsp56k.sh: drop the eight JP-8000 v1.5 firmware
# .mid files here. (In schwung-jp8000 this read dist/jp8000/roms.)
ROMS="${ROMS:-roms-ios/je8086}"
APP="$OUT/Standalone/JE8086.app"
if compgen -G "$ROMS/*.mid" > /dev/null; then
  for bundle in "$OUT/AUv3/JE8086.appex" "$APP" "$APP/PlugIns/JE8086.appex"; do
    [[ -d "$bundle" ]] || continue
    cp "$ROMS"/*.mid "$bundle/"
    # Ship the boot snapshot if one is staged. Neither this script nor its
    # schwung-je8086 predecessor copied it, and JE-8086 boots fine on an iPad
    # without it -- so this is a possible startup saving, not a fix. The docs
    # put a scratch boot at 30-60s against ~0.5s from a snapshot, but that gap
    # has not been observed here and the copy is harmless either way.
    compgen -G "$ROMS/*.snap" > /dev/null && cp "$ROMS"/*.snap "$bundle/"
  done
  if compgen -G "$ROMS/*.snap" > /dev/null; then
    echo "==> ROMs + boot snapshot copied into the app, the embedded .appex and the standalone .appex"
  else
    echo "==> ROMs copied into the app, the embedded .appex and the standalone .appex"
    echo "==> (no *.snap in $ROMS -- the firmware boots from scratch)"
  fi

  if [[ "$MODE" == "device" ]]; then
    # "Apple Development" alone is ambiguous when the keychain holds certs for
    # more than one team; resolve it to the one matching DEVELOPMENT_TEAM.
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
    for bundle in "$APP/PlugIns/JE8086.appex" "$APP" "$OUT/AUv3/JE8086.appex"; do
      [[ -d "$bundle" ]] || continue
      codesign --force --preserve-metadata=entitlements,identifier,flags \
               --sign "$IDENTITY" "$bundle" >/dev/null
    done
    echo "==> Re-signed (ROMs added after the build's own signing step)"
  fi
else
  echo "==> WARNING: no ROMs in $ROMS -- the plugin will boot silent"
fi

echo "==> Done. Artefacts under $OUT/"
