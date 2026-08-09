#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/release.sh <version>              # Developer ID + notarized release
#   scripts/release.sh <version> --unsigned   # ad-hoc signed public preview
#
# Full release pipeline:
#   1. Preflight (on fal-integration, tree clean, tag free, in sync with origin)
#   2. Bump CFBundleShortVersionString + auto-increment CFBundleVersion
#   3. Prompt for release notes in $EDITOR (prefilled with recent commits)
#   4. Build a notarized or unsigned preview DMG
#   5. Commit + push version bump
#   6. Tag + push tag
#   7. gh release create with the DMG and notes
#   8. Update creatorstudio-appcast.xml + commit + push
#
# Bails out before anything public-visible if a preflight check fails.

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 <version> [--unsigned]  (e.g. 0.1.0 --unsigned)" >&2
  exit 1
fi

VERSION="$1"
TAG="creatorstudio-v$VERSION"
RELEASE_MODE="signed"
if [ $# -eq 2 ]; then
  if [ "$2" != "--unsigned" ]; then
    echo "error: unknown release option: $2" >&2
    exit 1
  fi
  RELEASE_MODE="unsigned"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be X.Y.Z (got: $VERSION)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/PalmierPro/Resources/Info.plist"
APPCAST="$ROOT/creatorstudio-appcast.xml"
DMG="$ROOT/.build/CreatorStudioEditor.dmg"
cd "$ROOT"
RELEASE_REPOSITORY="mikefilsaime-groove/palmier-pro"
export RELEASE_REPOSITORY

echo "==> Preflight"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "fal-integration" ]; then
  echo "error: must be on fal-integration (got: $BRANCH)" >&2
  exit 1
fi

ORIGIN_URL="$(git remote get-url origin)"
case "$ORIGIN_URL" in
  https://github.com/mikefilsaime-groove/palmier-pro.git|git@github.com:mikefilsaime-groove/palmier-pro.git) ;;
  *) echo "error: origin is not $RELEASE_REPOSITORY (got: $ORIGIN_URL)" >&2; exit 1 ;;
esac

if ! git diff-index --quiet HEAD --; then
  echo "error: working tree has uncommitted changes:" >&2
  git status --short >&2
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists locally" >&2
  exit 1
fi

git fetch origin fal-integration --quiet
git fetch origin --tags --quiet
if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin" >&2
  exit 1
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/fal-integration)" ]; then
  echo "error: local fal-integration differs from origin/fal-integration. Push or pull first." >&2
  exit 1
fi

echo "==> Generating release notes from commit log"
NOTES_CLEAN="$(mktemp -t creatorstudio-editor-release.XXXXXX).md"
trap 'rm -f "$NOTES_CLEAN"' EXIT
LAST_TAG="$(git describe --tags --match 'creatorstudio-v*' --abbrev=0 2>/dev/null || echo '')"
{
  echo "## What's new"
  echo ""
  if [ -n "$LAST_TAG" ]; then
    git log --pretty=format:"- %s" "$LAST_TAG..HEAD"
    echo ""
  else
    echo "First release."
  fi
  if [ "$RELEASE_MODE" = "unsigned" ]; then
    echo ""
    echo "## Install this unsigned preview"
    echo ""
    echo "This build is ad-hoc signed but not Apple-notarized. It requires macOS 26 on an Apple Silicon Mac."
    echo ""
    echo "1. Download and open CreatorStudioEditor.dmg."
    echo "2. Drag CreatorStudio Editor to Applications."
    echo "3. Control-click the app, choose Open, then confirm Open."
    echo "4. If macOS still blocks it, use System Settings > Privacy & Security > Open Anyway."
  fi
} >"$NOTES_CLEAN"
echo "    (edit on GitHub later if you want to polish)"

echo "==> Bumping version"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
NEW_BUILD=$((CURRENT_BUILD + 1))

MAX_PUBLISHED="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$APPCAST" \
  | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
if [ -n "$MAX_PUBLISHED" ] && [ "$NEW_BUILD" -le "$MAX_PUBLISHED" ]; then
  echo "error: NEW_BUILD=$NEW_BUILD is not greater than max published sparkle:version=$MAX_PUBLISHED" >&2
  echo "       Info.plist CFBundleVersion ($CURRENT_BUILD) was likely rolled back by an unrelated commit." >&2
  echo "       Set CFBundleVersion to $MAX_PUBLISHED in $PLIST and retry." >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "    $VERSION (build $NEW_BUILD)"

echo "==> Building $RELEASE_MODE DMG"
BUILD_LOG="$(mktemp -t creatorstudio-editor-build.XXXXXX).log"
trap 'rm -f "$NOTES_CLEAN" "$BUILD_LOG"' EXIT
if [ "$RELEASE_MODE" = "unsigned" ]; then
  ./scripts/bundle.sh release --unsigned-dist 2>&1 | tee "$BUILD_LOG"
else
  ./scripts/bundle.sh release --dist 2>&1 | tee "$BUILD_LOG"
fi

# Only match the real signature line (which has length="<digits>"), not the
# instruction hint text that bundle.sh also prints.
SIG_LINE="$(grep -E 'edSignature="[^"]+".*length="[0-9]+"' "$BUILD_LOG" | tail -1)"
SIGNATURE="$(echo "$SIG_LINE" | sed -E 's/.*edSignature="([^"]+)".*/\1/')"
LENGTH="$(echo "$SIG_LINE" | sed -E 's/.*length="([0-9]+)".*/\1/')"
if [ -z "$SIGNATURE" ] || ! [[ "$LENGTH" =~ ^[0-9]+$ ]]; then
  echo "error: couldn't extract Sparkle signature or numeric length from build output" >&2
  echo "  got SIGNATURE=$SIGNATURE" >&2
  echo "  got LENGTH=$LENGTH" >&2
  exit 1
fi

echo "==> Committing + pushing version bump"
git add "$PLIST"
git commit -m "[build] Release CreatorStudio Editor $VERSION"
git push origin fal-integration

echo "==> Tagging $TAG"
git tag "$TAG"
git push origin "$TAG"

echo "==> Creating GH release"
GH_RELEASE_ARGS=(release create "$TAG" "$DMG" --repo "$RELEASE_REPOSITORY" --notes-file "$NOTES_CLEAN")
if [ "$RELEASE_MODE" = "unsigned" ]; then
  GH_RELEASE_ARGS+=(--prerelease --title "CreatorStudio Editor $VERSION Preview")
else
  GH_RELEASE_ARGS+=(--title "CreatorStudio Editor $VERSION")
fi
gh "${GH_RELEASE_ARGS[@]}"

echo "==> Updating creatorstudio-appcast.xml"
PUBDATE="$(date -R)"
export VERSION NEW_BUILD PUBDATE LENGTH SIGNATURE
python3 <<'PYEOF'
import os
v = os.environ["VERSION"]
b = os.environ["NEW_BUILD"]
d = os.environ["PUBDATE"]
l = os.environ["LENGTH"]
s = os.environ["SIGNATURE"]
repo = os.environ["RELEASE_REPOSITORY"]
url = f"https://github.com/{repo}/releases/download/creatorstudio-v{v}/CreatorStudioEditor.dmg"

item = f"""        <item>
            <title>Version {v}</title>
            <pubDate>{d}</pubDate>
            <sparkle:version>{b}</sparkle:version>
            <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <enclosure
                url="{url}"
                length="{l}"
                type="application/octet-stream"
                sparkle:edSignature="{s}"/>
        </item>"""

path = "creatorstudio-appcast.xml"
with open(path) as f:
    content = f.read()
content = content.replace("    </channel>", item + "\n    </channel>")
with open(path, "w") as f:
    f.write(content)
PYEOF

git add "$APPCAST"
git commit -m "[build] Publish CreatorStudio Editor $VERSION appcast"
git push origin fal-integration

echo ""
echo "==> Released $TAG"
echo "    https://github.com/$RELEASE_REPOSITORY/releases/tag/$TAG"
echo "    https://github.com/$RELEASE_REPOSITORY/releases/download/$TAG/CreatorStudioEditor.dmg"
