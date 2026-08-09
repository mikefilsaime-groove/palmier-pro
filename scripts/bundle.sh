#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign, just env+build
#   scripts/bundle.sh debug --speech             # include bundled speech and MLX
#   scripts/bundle.sh debug --all                # include all optional traits
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG
#   scripts/bundle.sh release --unsigned-dist   # ad-hoc signed preview DMG + Sparkle signature

CONFIG="release"
MODE="dev"
ENABLE_ALL_TRAITS=false
INCLUDE_BUNDLED_SPEECH=false
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    --unsigned-dist) MODE="unsigned-dist" ;;
    --speech)      INCLUDE_BUNDLED_SPEECH=true ;;
    --all)
      ENABLE_ALL_TRAITS=true
      INCLUDE_BUNDLED_SPEECH=true
      ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [ "$CONFIG" = "release" ] && [ "$MODE" != "unsigned-dist" ]; then
  INCLUDE_BUNDLED_SPEECH=true
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ENV_FILE=".env"
if [ "$CONFIG" = "release" ] && [ -f "$ROOT/.env.prod" ]; then
  ENV_FILE=".env.prod"
fi
if [ -f "$ROOT/$ENV_FILE" ]; then
  echo "==> Loading $ENV_FILE"
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/$ENV_FILE"
  set +a
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-creatorstudio-editor}"
RESOURCES="$ROOT/Sources/PalmierPro/Resources"
APP="$ROOT/.build/CreatorStudioEditor.app"
ZIP="$ROOT/.build/CreatorStudioEditor.zip"
DMG="$ROOT/.build/CreatorStudioEditor.dmg"

BUILD_ARGS=(-c "$CONFIG")
if $ENABLE_ALL_TRAITS; then
  TRAITS="all"
  BUILD_ARGS+=(--enable-all-traits)
else
  TRAITS=""
  if $INCLUDE_BUNDLED_SPEECH; then
    TRAITS="BundledSpeech"
  fi
  if [ -n "$TRAITS" ]; then
    BUILD_ARGS+=(--traits "$TRAITS")
  fi
fi

echo "==> Resolving Swift packages"
swift package resolve
LOTTIE_CHECKOUT="$ROOT/.build/checkouts/lottie-ios"
LOTTIE_ENTRY_FILE="$LOTTIE_CHECKOUT/Sources/Private/EmbeddedLibraries/EpoxyCore/SwiftUI/EpoxySwiftUILayoutMargins.swift"
if [ -f "$LOTTIE_ENTRY_FILE" ] && grep -q '@Entry var epoxyLayoutMargins' "$LOTTIE_ENTRY_FILE"; then
  echo "==> Applying Lottie 4.6.1 Command Line Tools compatibility patch"
  patch --batch --forward --no-backup-if-mismatch -d "$LOTTIE_CHECKOUT" -p1 \
    < "$ROOT/scripts/patches/lottie-4.6.1-command-line-tools.patch"
fi

echo "==> Building ($CONFIG, traits: ${TRAITS:-none})"
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/PalmierPro"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/PalmierPro"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

inject_plist() {
  local key="$1" value="$2"
  if [ -z "$value" ]; then
    return
  fi
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP/Contents/Info.plist"
}

if [ "$MODE" = "sign" ] || [ "$MODE" = "dist" ]; then
  if [ -z "$SIGNING_IDENTITY" ]; then
    echo "!! SIGNING_IDENTITY is required for a signed CreatorStudio Editor build" >&2
    exit 1
  fi
fi
if [ "$MODE" = "sign" ] || [ "$MODE" = "dist" ] || [ "$MODE" = "unsigned-dist" ]; then
  if [ -z "$SPARKLE_FEED_URL" ] || [ -z "$SPARKLE_PUBLIC_KEY" ]; then
    echo "!! SPARKLE_FEED_URL and SPARKLE_PUBLIC_KEY are required for a distribution build" >&2
    exit 1
  fi
  inject_plist SUFeedURL "$SPARKLE_FEED_URL"
  inject_plist SUPublicEDKey "$SPARKLE_PUBLIC_KEY"
fi
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/PalmierPro_PalmierPro.bundle"
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

# Ensure the shipped Claude Desktop connector is always up to date with mcpb/ sources.
MCPB_SRC="$ROOT/mcpb"
MCPB_CHECKED_IN="$ROOT/Sources/PalmierPro/Resources/MCPB/palmier-pro.mcpb"
MCPB_FRESH="$(mktemp -d)/palmier-pro.mcpb"
(cd "$MCPB_SRC" && zip -q -X -r "$MCPB_FRESH" manifest.json icon.png server/index.js server/package.json)
if ! unzip -p "$MCPB_CHECKED_IN" server/index.js 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" server/index.js) >/dev/null 2>&1 \
  || ! unzip -p "$MCPB_CHECKED_IN" manifest.json 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" manifest.json) >/dev/null 2>&1; then
  echo "==> refreshing checked-in palmier-pro.mcpb from mcpb/ sources"
  cp "$MCPB_FRESH" "$MCPB_CHECKED_IN"
fi
cp "$MCPB_FRESH" "$APP/Contents/Resources/palmier-pro.mcpb"
rm -rf "$(dirname "$MCPB_FRESH")"
if [ -d "$RES_BUNDLE/Images" ]; then
  cp -R "$RES_BUNDLE/Images" "$APP/Contents/Resources/"
fi
# .lproj folders must live at the bundle root for macOS to resolve them.
LOCALIZATION_COUNT=0
for locale_dir in "$RES_BUNDLE"/*.lproj; do
  [ -d "$locale_dir" ] || continue
  for strings_file in Localizable.strings InfoPlist.strings; do
    if [ ! -f "$locale_dir/$strings_file" ]; then
      echo "!! missing $strings_file in $locale_dir" >&2
      exit 1
    fi
  done
  cp -R "$locale_dir" "$APP/Contents/Resources/"
  LOCALIZATION_COUNT=$((LOCALIZATION_COUNT + 1))
done
if [ "$LOCALIZATION_COUNT" -eq 0 ]; then
  echo "!! no compiled localizations in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Changelog" ]; then
  cp -R "$RES_BUNDLE/Changelog" "$APP/Contents/Resources/"
else
  echo "!! missing Changelog/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Models" ]; then
  cp -R "$RES_BUNDLE/Models" "$APP/Contents/Resources/"
else
  echo "!! missing Models/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

if ls "$RES_BUNDLE"/*.metallib >/dev/null 2>&1; then
  cp "$RES_BUNDLE"/*.metallib "$APP/Contents/Resources/"
elif { [ "$MODE" = "fast" ] && [ "$CONFIG" = "debug" ]; } || [ "$MODE" = "unsigned-dist" ]; then
  echo "!! Metal effects unavailable in this preview bundle; install full Xcode to compile .metallib resources" >&2
else
  echo "!! no .metallib in SwiftPM resource bundle at $RES_BUNDLE — Metal effects would be missing" >&2
  exit 1
fi

if $INCLUDE_BUNDLED_SPEECH; then
  MLX_METALLIB="$ROOT/.build/$CONFIG/mlx.metallib"
  if [ ! -f "$MLX_METALLIB" ]; then
    echo "==> Building MLX metallib ($CONFIG)"
    BUILD_DIR="$ROOT/.build" "$ROOT/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh" "$CONFIG"
  fi
  if [ ! -f "$MLX_METALLIB" ]; then
    echo "!! missing $MLX_METALLIB — on-device speech features (VAD, speaker ID) would die silently" >&2
    exit 1
  fi
  mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
  cp "$MLX_METALLIB" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
fi

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PalmierPro"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  FAST_SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
  echo "==> Codesigning main app with $FAST_SIGNING_IDENTITY (no timestamp, no helpers)"
  codesign --force --sign "$FAST_SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM)"
  exit 0
fi

DSYM="$ROOT/.build/PalmierPro.dSYM"
echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/PalmierPro" -o "$DSYM"

if [ "$MODE" = "dev" ]; then
  echo "==> Ad-hoc signing dev app"
  codesign --force --deep --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "==> Done: $APP (ad-hoc signed)"
  exit 0
fi

build_dmg() {
  echo "==> Building DMG"
  rm -f "$DMG"
  local staging
  staging="$(mktemp -d)"
  cp -R "$APP" "$staging/CreatorStudio Editor.app"
  ln -s /Applications "$staging/Applications"
  cp "$RESOURCES/AppIcon.icns" "$staging/.VolumeIcon.icns"
  hdiutil create \
    -volname "CreatorStudio Editor" \
    -srcfolder "$staging" \
    -ov -format UDZO \
    "$DMG"
  rm -rf "$staging"
}

print_sparkle_signature() {
  echo "==> Signing DMG with Sparkle EdDSA key"
  local signature
  signature="$("$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
    --account "$SPARKLE_KEY_ACCOUNT" "$DMG")"
  echo ""
  echo "==> Done"
  echo "   App: $APP"
  echo "   DMG: $DMG"
  echo ""
  echo "Sparkle signature for appcast entry:"
  echo "  $signature"
}

if [ "$MODE" = "unsigned-dist" ]; then
  echo "==> Ad-hoc signing unsigned preview app"
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  build_dmg
  echo "==> Ad-hoc signing unsigned preview DMG"
  codesign --force --sign - "$DMG"
  codesign --verify --verbose=2 "$DMG"
  print_sparkle_signature
  echo ""
  echo "This preview is not notarized. First launch requires Control-click > Open."
  exit 0
fi

echo "==> Codesigning nested Sparkle helpers"
SPARKLE_CURRENT="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for helper in \
    "$SPARKLE_CURRENT/Autoupdate" \
    "$SPARKLE_CURRENT/Updater.app/Contents/MacOS/Updater" \
    "$SPARKLE_CURRENT/Updater.app" \
    "$SPARKLE_CURRENT/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$SPARKLE_CURRENT/XPCServices/Downloader.xpc" \
    "$SPARKLE_CURRENT/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$SPARKLE_CURRENT/XPCServices/Installer.xpc"; do
  [ -e "$helper" ] && codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$helper"
done

echo "==> Codesigning Sparkle framework"
codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> Codesigning main app"
codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$MODE" = "sign" ]; then
  echo "==> Done: $APP (signed, not notarized)"
  exit 0
fi

echo "==> Zipping .app for notarization"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary (this can take several minutes)"
if [ -z "$NOTARY_PROFILE" ]; then
  echo "!! NOTARY_PROFILE is required for distribution" >&2
  exit 1
fi
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling ticket to .app"
xcrun stapler staple "$APP"
rm -f "$ZIP"

build_dmg

echo "==> Codesigning DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

echo "==> Submitting DMG to notary"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"

print_sparkle_signature
echo ""
echo "Add an <item> to appcast.xml with:"
echo "  - version, shortVersionString from Info.plist"
echo "  - url pointing at the GitHub Release download"
echo "  - length=$(stat -f%z "$DMG")"
echo "  - the sparkle:edSignature from above"
