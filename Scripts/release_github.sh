#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="DJIImporter"
PROJECT="DJIImporter.xcodeproj"
SCHEME="DJIImporter"
CONFIGURATION="Release"
DERIVED_DATA_PATH=".build/DerivedData"
DIST_DIR="dist"
REPO="${GITHUB_REPOSITORY:-jjyr/dji-importer}"

usage() {
  cat <<'EOF'
Usage: Scripts/release_github.sh [--dry-run]

Builds the signed macOS app, zips DJIImporter.app, writes sha256 output, and
creates or updates the matching GitHub release asset.

Environment:
  VERSION=0.1.0                 Override MARKETING_VERSION from the Xcode project.
  GITHUB_REPOSITORY=owner/name  Override GitHub repository. Default: jjyr/dji-importer.
  CODE_SIGN_IDENTITY=-          Override signing identity. Default: ad-hoc signing.
  ALLOW_DIRTY=1                 Allow releasing with a dirty git worktree.
EOF
}

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command xcodebuild
require_command codesign
require_command ditto
require_command shasum
require_command gh
require_command awk

if [[ "${ALLOW_DIRTY:-0}" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to release from a dirty worktree. Commit changes first, or set ALLOW_DIRTY=1." >&2
  git status --short >&2
  exit 1
fi

VERSION="${VERSION:-$(awk -F' = ' '/MARKETING_VERSION = / { gsub(/;/, "", $2); print $2; exit }' "$PROJECT/project.pbxproj")}"
if [[ -z "$VERSION" ]]; then
  echo "Could not determine MARKETING_VERSION from $PROJECT/project.pbxproj" >&2
  exit 1
fi
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

TAG="v${VERSION}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
ZIP_NAME="${APP_NAME}.app.zip"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"
SHA_PATH="${ZIP_PATH}.sha256"
COMMIT_SHA="$(git rev-parse HEAD)"

echo "Release: $TAG"
echo "Commit:  $COMMIT_SHA"
echo "Repo:    $REPO"

xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce expected app: $APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$SHA_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{ print $1 }')"
printf "%s  %s\n" "$SHA256" "$ZIP_NAME" > "$SHA_PATH"

echo "Artifact: $ZIP_PATH"
echo "SHA256:   $SHA256"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete; GitHub release was not changed."
  exit 0
fi

NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<EOF
DJI Importer ${VERSION}

- Signed macOS app build for direct distribution.
- Imports JPG, JPEG, and MP4 files into Apple Photos.
- Photos duplicate detection is enabled during import.

SHA256:

\`\`\`
${SHA256}  ${ZIP_NAME}
\`\`\`
EOF

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists; uploading assets with --clobber."
  gh release upload "$TAG" "$ZIP_PATH#${ZIP_NAME}" "$SHA_PATH#${ZIP_NAME}.sha256" \
    --repo "$REPO" \
    --clobber
else
  echo "Creating release $TAG."
  gh release create "$TAG" "$ZIP_PATH#${ZIP_NAME}" "$SHA_PATH#${ZIP_NAME}.sha256" \
    --repo "$REPO" \
    --target "$COMMIT_SHA" \
    --title "$TAG" \
    --notes-file "$NOTES_FILE"
fi

echo "Release URL:"
gh release view "$TAG" --repo "$REPO" --json url --jq .url
