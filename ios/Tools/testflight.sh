#!/usr/bin/env bash
# Archive the app (Release) and upload it to App Store Connect for TestFlight.
#
# One-time setup (App Store Connect, needs your Apple login):
#   1. Users and Access › Integrations › App Store Connect API › Team Keys: generate a key with the
#      "App Manager" (or Admin) role. Download AuthKey_<KEY_ID>.p8 to
#      ~/.appstoreconnect/private_keys/ and note the Key ID and the Issuer ID.
#   2. Apps › + › New App: platform iOS, name "Omi Notes" (or any available name), bundle ID
#      $BUNDLE_ID (register it first under Certificates, Identifiers & Profiles if it isn't
#      listed), any SKU.
#
# Then:  ASC_KEY_ID=… ASC_ISSUER_ID=… ios/Tools/testflight.sh
#
# Signing is fully automatic: with the API key, Xcode creates the distribution certificate and
# App Store profile in the cloud (-allowProvisioningUpdates). Nothing is stored in this repo.
set -euo pipefail
cd "$(dirname "$0")/.."  # ios/

: "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API key id)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect API issuer id)}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[[ -f "$KEY_PATH" ]] || { echo "API key not found at $KEY_PATH (set ASC_KEY_PATH)" >&2; exit 1; }

# Team and bundle id: environment, else Config/Local.xcconfig, else Config/Base.xcconfig.
setting() {
    local key=$1 file value=""
    for file in Config/Local.xcconfig Config/Base.xcconfig; do
        [[ -f $file ]] || continue
        value=$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^[:space:]/]+).*/\1/p" "$file" | tail -1)
        [[ -n $value ]] && { echo "$value"; return; }
    done
}
TEAM_ID="${TEAM_ID:-$(setting DEVELOPMENT_TEAM)}"
BUNDLE_ID="${BUNDLE_ID:-$(setting PRODUCT_BUNDLE_IDENTIFIER)}"
[[ -n $TEAM_ID ]] || { echo "No team id: set TEAM_ID or DEVELOPMENT_TEAM in Config/Local.xcconfig" >&2; exit 1; }
# Must increase with every upload of the same version.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "Team $TEAM_ID · bundle $BUNDLE_ID · build $BUILD_NUMBER"
rm -rf build/testflight && mkdir -p build/testflight
xcodegen generate

xcodebuild archive \
    -project OmiNotes.xcodeproj -scheme OmiNotes -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath build/testflight/OmiNotes.xcarchive \
    DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGN_STYLE=Automatic \
    "${AUTH[@]}"

cat > build/testflight/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath build/testflight/OmiNotes.xcarchive \
    -exportOptionsPlist build/testflight/ExportOptions.plist \
    -exportPath build/testflight/export \
    "${AUTH[@]}"

echo
echo "Uploaded build $BUILD_NUMBER. It appears in App Store Connect › TestFlight after processing"
echo "(usually 5–15 min). Add yourself under Internal Testing to install it with the TestFlight app."
