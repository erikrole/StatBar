#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="StatBar.xcodeproj"
SCHEME="StatBar"
CONFIGURATION="Release"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

for command in xcodegen xcodebuild security codesign ditto xcrun shasum lipo git python3 spctl tar; do
    require_command "$command"
done

TEAM_ID="${TEAM_ID:-}"
if [[ -z "$TEAM_ID" ]]; then
    echo "TEAM_ID is required for Developer ID distribution." >&2
    exit 2
fi

DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-}"
if [[ -z "$DEVELOPER_IDENTITY" ]]; then
    DEVELOPER_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$DEVELOPER_IDENTITY" ]]; then
    echo "No Developer ID Application certificate is installed." >&2
    echo "Install one from the Apple Developer account before creating a release." >&2
    exit 2
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ASC_PROFILE="${ASC_PROFILE:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
NOTARY_PRIVATE_KEY_PATH="${NOTARY_PRIVATE_KEY_PATH:-}"
if [[ -z "$ASC_PROFILE" && -z "$NOTARY_PROFILE" && ( -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" || -z "$NOTARY_PRIVATE_KEY_PATH" ) ]]; then
    echo "Provide ASC_PROFILE, NOTARY_PROFILE, or NOTARY_KEY_ID, NOTARY_ISSUER_ID, and NOTARY_PRIVATE_KEY_PATH." >&2
    exit 2
fi
if [[ -n "$ASC_PROFILE" ]]; then require_command asc; fi

xcodegen generate
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit the reviewed source before creating release artifacts." >&2
    exit 1
fi
SOURCE_COMMIT="$(git rev-parse HEAD)"
BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -showBuildSettings -json)"
read -r VERSION BUILD_NUMBER < <(python3 -c '
import json, sys
settings = next(item["buildSettings"] for item in json.load(sys.stdin) if item["target"] == "StatBar")
print(settings["MARKETING_VERSION"], settings["CURRENT_PROJECT_VERSION"])
' <<< "$BUILD_SETTINGS")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "Could not read the release version and build number." >&2
    exit 1
}

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/.release/${VERSION}-${SOURCE_COMMIT:0:7}}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
if [[ -n "$(ls -A "$OUTPUT_DIR")" ]]; then
    echo "Use an empty OUTPUT_DIR; existing release evidence will not be overwritten: $OUTPUT_DIR" >&2
    exit 2
fi
ARCHIVE_PATH="$OUTPUT_DIR/StatBar.xcarchive"
EXPORT_PATH="$OUTPUT_DIR/StatBar-export"

ZIP_PATH="$OUTPUT_DIR/StatBar-${VERSION}-arm64.zip"
SHA_PATH="$ZIP_PATH.sha256"
NOTARY_ZIP="$OUTPUT_DIR/notarization-upload.zip"
NOTARY_RESULT="$OUTPUT_DIR/notarization.json"

# Build an immutable committed snapshot, so edits or commits in the working
# checkout during the archive cannot make its provenance manifest inaccurate.
SOURCE_PATH="$OUTPUT_DIR/source"
mkdir "$SOURCE_PATH"
git archive --format=tar "$SOURCE_COMMIT" | tar -xf - -C "$SOURCE_PATH"
PROJECT="$SOURCE_PATH/StatBar.xcodeproj"

xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$DEVELOPER_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES \
    ARCHS=arm64

EXPORT_OPTIONS="$OUTPUT_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/StatBar.app"

test -d "$APP_PATH" || {
    echo "Export did not produce $APP_PATH" >&2
    exit 1
}

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNING_DETAILS="$(codesign -dvvv "$APP_PATH" 2>&1)"
[[ "$SIGNING_DETAILS" == *"Authority=Developer ID Application"* ]] || {
    echo "Export is not signed with Developer ID Application: $DEVELOPER_IDENTITY" >&2
    exit 1
}
[[ "$SIGNING_DETAILS" == *"Timestamp="* ]] || {
    echo "Export does not contain a secure signing timestamp." >&2
    exit 1
}
[[ "$SIGNING_DETAILS" == *"TeamIdentifier=$TEAM_ID"* && "$SIGNING_DETAILS" == *"runtime"* ]] || {
    echo "Export has the wrong signing team or lacks Hardened Runtime." >&2
    exit 1
}

ARCHITECTURES="$(lipo -archs "$APP_PATH/Contents/MacOS/StatBar")"
[[ "$ARCHITECTURES" == "arm64" ]] || {
    echo "Export contains unexpected architectures: $ARCHITECTURES" >&2
    exit 1
}

ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"

if [[ -n "$ASC_PROFILE" ]]; then
    asc --profile "$ASC_PROFILE" notarization submit --file "$NOTARY_ZIP" --wait --output json > "$NOTARY_RESULT"
elif [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_RESULT"
else
    xcrun notarytool submit "$NOTARY_ZIP" \
        --key "$NOTARY_PRIVATE_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" \
        --wait --output-format json > "$NOTARY_RESULT"
fi
python3 -c '
import json, sys
result = json.load(open(sys.argv[1]))
status = result.get("status") or result.get("data", {}).get("attributes", {}).get("status")
if status != "Accepted":
    sys.exit("Notarization was not accepted; inspect " + sys.argv[1])
' "$NOTARY_RESULT"

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
(
    cd "$(dirname "$ZIP_PATH")"
    shasum -a 256 "$(basename "$ZIP_PATH")"
) > "$SHA_PATH"

# Verify the shipped ZIP after extraction, rather than relying on the export alone.
VERIFY_PATH="$OUTPUT_DIR/verification"
mkdir "$VERIFY_PATH"
ditto -x -k "$ZIP_PATH" "$VERIFY_PATH"
VERIFIED_APP="$VERIFY_PATH/StatBar.app"
codesign --verify --deep --strict --verbose=2 "$VERIFIED_APP"
xcrun stapler validate "$VERIFIED_APP"
spctl --assess --type execute --verbose=2 "$VERIFIED_APP"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 -c "$(basename "$SHA_PATH")"
)
python3 - "$SOURCE_COMMIT" "$VERSION" "$BUILD_NUMBER" "$TEAM_ID" "$OUTPUT_DIR" <<'PY'
import hashlib, json, pathlib, plistlib, subprocess, sys
source, version, build, team, directory = sys.argv[1:]
root = pathlib.Path(directory)
with (root / "verification/StatBar.app/Contents/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["CFBundleIdentifier"] == "com.erole.StatBar"
assert info["CFBundleShortVersionString"] == version
assert info["CFBundleVersion"] == build
assert info["LSMinimumSystemVersion"] == "27.0"
binary = root / "verification/StatBar.app/Contents/MacOS/StatBar"
build_info = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
assert any(line.split() == ["minos", "27.0"] for line in build_info.splitlines()), build_info
artifact = root / f"StatBar-{version}-arm64.zip"
notary = json.loads((root / "notarization.json").read_text())
notary_id = notary.get("id") or notary.get("data", {}).get("id")
notary_status = notary.get("status") or notary.get("data", {}).get("attributes", {}).get("status")
assert notary_id and notary_status == "Accepted"
manifest = {
    "source_commit": source, "version": version, "build": build,
    "bundle_identifier": info["CFBundleIdentifier"], "minimum_macos": info["LSMinimumSystemVersion"],
    "architecture": "arm64", "team_id": team,
    "notarization": {"id": notary_id, "status": notary_status},
    "verification": {"signature": True, "stapled_ticket": True, "gatekeeper": True, "checksum": True},
    "artifact": {"name": artifact.name, "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest()},
}
(root / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "Release artifacts:"
echo "  $ZIP_PATH"
echo "  $SHA_PATH"
echo "  $OUTPUT_DIR/release-manifest.json"
echo "Prepared from $SOURCE_COMMIT; GitHub publication is a separate step."
