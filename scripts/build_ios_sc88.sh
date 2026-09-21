#!/usr/bin/env bash
#
# Build the SC-88 (88emuPlayer) for iOS (AUv3 + Standalone host app; the .appex
# is embedded in the app).
#
#   scripts/build_ios_sc88.sh                                   # simulator
#   DEVELOPMENT_TEAM=<YOUR_TEAM_ID> scripts/build_ios_sc88.sh device
#
# Not a DSP56300 synth and not the ESP: 88emu emulates an H8S with Roland's
# custom PCM chips, so neither pgo/dsp56k.profdata nor pgo/je8086.profdata
# applies and no profile is used here. The custom_chips XP DSP runs naively on
# iOS for the usual reason -- no executable pages, so its JIT cannot be used.
#
# The module reaches the plugin formats through its own juce_add_plugin() call
# rather than createJucePlugin(), so the iOS-specific pieces (microphone usage
# description, PRODUCTS_FOLDER suffix, no install() rule, portmidi skipped) live
# in 88emuplayer/CMakeLists.txt itself.
#
# ROMs: a complete set is control plus four 2 MB wave images, content-addressed
# by hash in 88lib/romRegistry.h. Without them the plugin boots silent.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-simulator}"
PRODUCT="88emuPlayer"
TARGET=88emuplayer_All

ROMS="${ROMS:-roms-ios/sc88}"

BUILD_DIR="build-ios-sc88"
[[ "$MODE" == "device" ]] && BUILD_DIR="$BUILD_DIR-device"
EXTRA_BUILD_ARGS=()

COMMON_ARGS=(
  # EXTRA_CXX_FLAGS lets a caller add defines without editing this script.
  -DCMAKE_CXX_FLAGS="${EXTRA_CXX_FLAGS:-}"
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
  -Dgearmulator_SYNTH_JE8086=off
  -Dgearmulator_SYNTH_88EMU=on
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

# emu88Lib::RomLoader sweeps the directory the loaded binary sits in, which for
# an iOS bundle is the bundle root. The AUv3 a host loads is the one EMBEDDED in
# the app (PlugIns/), so it needs its own copy; adding files to a signed bundle
# invalidates the signature, so re-sign inside-out afterwards.
APP="$OUT/Standalone/$PRODUCT.app"
if compgen -G "$ROMS/*" > /dev/null 2>&1; then
  copied=0
  for bundle in "$OUT/AUv3/$PRODUCT.appex" "$APP" "$APP/PlugIns/$PRODUCT.appex"; do
    [[ -d "$bundle" ]] || continue
    # the loader filters by SIZE first and only then hashes, so anything that is
    # not a registered image costs a stat and nothing more.
    find "$ROMS" -maxdepth 1 -type f -iname '*.bin' \
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
  echo "    expected there: one control .bin plus four 2 MB wave .bin images"
fi

echo "==> Done. Artefacts under $OUT/"
