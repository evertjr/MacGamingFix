#!/bin/bash
set -euo pipefail

# --- Configuration ---
PROJECT="MacGamingFix.xcodeproj"
SCHEME="MacGamingFix"
APP_NAME="MacGamingFix"
BUILD_DIR="build"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}▸${NC} $1"; }
warn()  { echo -e "${YELLOW}▸${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# --- Preflight checks ---
command -v xcodebuild >/dev/null 2>&1 || error "xcodebuild not found. Install Xcode."
command -v gh >/dev/null 2>&1          || error "gh CLI not found. Install with: brew install gh"
gh auth status >/dev/null 2>&1         || error "Not authenticated with gh. Run: gh auth login"

# Ensure we're on a clean working tree
if [[ -n "$(git status --porcelain)" ]]; then
  error "Working tree is dirty. Commit or stash your changes first."
fi

# --- Determine version ---
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo -e "\n${BOLD}Usage:${NC} ./scripts/release.sh <version>"
  echo -e "  Example: ./scripts/release.sh 1.0.0"
  echo -e "  Example: ./scripts/release.sh 1.1.0-beta.1\n"
  exit 1
fi

# Validate semver-ish format
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  error "Invalid version format: $VERSION (expected: X.Y.Z or X.Y.Z-label)"
fi

TAG="v$VERSION"

# Check tag doesn't already exist
if git rev-parse "$TAG" >/dev/null 2>&1; then
  error "Tag $TAG already exists."
fi

# --- Update version in Xcode project ---
info "Setting marketing version to $VERSION..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  MARKETING_VERSION="$VERSION" -showBuildSettings >/dev/null 2>&1

# --- Build Release ---
info "Building $APP_NAME (Release)..."
rm -rf "$BUILD_DIR"

xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  CODE_SIGN_IDENTITY="-" \
  clean build 2>&1 | tail -5

APP_PATH=$(find "$BUILD_DIR/derived" -name "$APP_NAME.app" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
  error "Build failed — $APP_NAME.app not found."
fi

info "Build succeeded: $APP_PATH"

# --- Package ---
RELEASE_DIR="$BUILD_DIR/release"
mkdir -p "$RELEASE_DIR"

ZIP_NAME="$APP_NAME-$VERSION-macos.zip"
info "Packaging $ZIP_NAME..."
ditto -c -k --keepParent "$APP_PATH" "$RELEASE_DIR/$ZIP_NAME"

ZIP_SIZE=$(du -h "$RELEASE_DIR/$ZIP_NAME" | cut -f1 | xargs)
info "Package ready: $ZIP_NAME ($ZIP_SIZE)"

# --- Tag & push ---
info "Creating tag $TAG..."
git tag -a "$TAG" -m "Release $VERSION"
git push origin "$TAG"

# --- Create GitHub Release ---
IS_PRERELEASE=""
if [[ "$VERSION" == *-* ]]; then
  IS_PRERELEASE="--prerelease"
fi

# Open editor for release notes
NOTES_FILE=$(mktemp)
echo "# Release notes for $APP_NAME $VERSION" > "$NOTES_FILE"
echo "# Lines starting with # will be ignored." >> "$NOTES_FILE"
echo "" >> "$NOTES_FILE"

info "Opening editor for release notes..."
"${EDITOR:-vim}" "$NOTES_FILE"

# Strip comment lines and check for content
NOTES=$(grep -v '^#' "$NOTES_FILE" | sed '/^$/N;/^\n$/d')
rm -f "$NOTES_FILE"

if [[ -z "$NOTES" ]]; then
  error "Empty release notes. Aborting release."
fi

info "Creating GitHub release..."
gh release create "$TAG" \
  "$RELEASE_DIR/$ZIP_NAME" \
  --title "$APP_NAME $VERSION" \
  --notes "$NOTES" \
  $IS_PRERELEASE

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)

echo ""
echo -e "${GREEN}${BOLD}✓ Release $VERSION published!${NC}"
echo -e "  ${RELEASE_URL}"
echo ""

# --- Cleanup ---
rm -rf "$BUILD_DIR"
