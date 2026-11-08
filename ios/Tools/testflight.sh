#!/usr/bin/env bash
# Archive a Release build of HEAD, sign each target with its existing App Store profile (manual
# signing), export the IPA, check it, and with --upload send it to App Store Connect. Nothing is
# created on Apple's side: the App IDs, the Apple Distribution certificate and the four profiles
# must already exist and be installed.
#
#   TEAM_ID=ABCDE12345 OMI_BUILD_NUMBER=39 \
#   OMI_IOS_PROFILE='Omi Notes App Store' \
#   OMI_WATCH_PROFILE='Omi Notes Watch App Store' \
#   OMI_COMPLICATION_PROFILE='Omi Notes Watch Complication App Store' \
#   OMI_LIVE_ACTIVITY_PROFILE='Omi Notes Live Activity App Store' \
#   ios/Tools/testflight.sh [--upload]
#
# Optional: OMI_APP_BUNDLE_ID and OMI_MARKETING_VERSION (default: Config/Base.xcconfig; the Watch app,
# complication and Live Activity derive their ids from the bundle id), SIGNING_CERTIFICATE (SHA-1 of the Apple
# Distribution identity; default: the only one installed), OMI_RELEASE_DIR (default:
# build/testflight-ready/OmiNotes-<version>-<build>). --upload needs ASC_KEY_ID and ASC_ISSUER_ID
# with ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8. An upload doesn't reach testers by
# itself: add the processed build to a TestFlight group afterwards.
#
# The build comes from a clean copy of the committed tree, so a personal Config/Local.xcconfig and
# uncommitted changes never reach it.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

UPLOAD=no
[[ ${1:-} == --upload ]] && UPLOAD=yes

: "${TEAM_ID:?set TEAM_ID}"
: "${OMI_BUILD_NUMBER:?set OMI_BUILD_NUMBER (higher than every build of this version in App Store Connect)}"
: "${OMI_IOS_PROFILE:?set OMI_IOS_PROFILE (App Store profile of the app)}"
: "${OMI_WATCH_PROFILE:?set OMI_WATCH_PROFILE (App Store profile of the Watch app)}"
: "${OMI_COMPLICATION_PROFILE:?set OMI_COMPLICATION_PROFILE (App Store profile of the complication)}"
: "${OMI_LIVE_ACTIVITY_PROFILE:?set OMI_LIVE_ACTIVITY_PROFILE (App Store profile of the Live Activity)}"
base() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]/]+).*/\1/p" ios/Config/Base.xcconfig | tail -1; }
BUNDLE_ID=${OMI_APP_BUNDLE_ID:-$(base OMI_APP_BUNDLE_ID)}
VERSION=${OMI_MARKETING_VERSION:-$(base MARKETING_VERSION)}
if [[ -z ${SIGNING_CERTIFICATE:-} ]]; then
    certs=$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "Apple Distribution.*/\1/p')
    [[ $(wc -l <<<"$certs") -eq 1 && -n $certs ]] || { echo "Set SIGNING_CERTIFICATE (found: ${certs:-none})" >&2; exit 1; }
    SIGNING_CERTIFICATE=$certs
fi
REL=${OMI_RELEASE_DIR:-$ROOT/build/testflight-ready/OmiNotes-$VERSION-$OMI_BUILD_NUMBER}
[[ -z $(git status --porcelain) ]] || { echo "Commit or set aside your changes first: the build is made from HEAD" >&2; exit 1; }
[[ ! -e $REL/export ]] || { echo "$REL already has an export; pick a new build number or directory" >&2; exit 1; }

echo "Omi Notes $VERSION ($OMI_BUILD_NUMBER) · $BUNDLE_ID · team $TEAM_ID · $(git rev-parse --short HEAD) → $REL"
mkdir -p "$REL"
git rev-parse HEAD > "$REL/source-commit.txt"
rm -rf "$REL/source" && mkdir -p "$REL/source"
git archive HEAD | tar -x -C "$REL/source"
(cd "$REL/source/ios" && xcodegen generate)

xcodebuild archive \
    -project "$REL/source/ios/OmiNotes.xcodeproj" -scheme OmiNotes -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$REL/OmiNotes.xcarchive" -derivedDataPath "$REL/DerivedData" \
    DEVELOPMENT_TEAM="$TEAM_ID" OMI_APP_BUNDLE_ID="$BUNDLE_ID" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$OMI_BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
    OMI_IOS_PROFILE="$OMI_IOS_PROFILE" OMI_WATCH_PROFILE="$OMI_WATCH_PROFILE" \
    OMI_COMPLICATION_PROFILE="$OMI_COMPLICATION_PROFILE" OMI_LIVE_ACTIVITY_PROFILE="$OMI_LIVE_ACTIVITY_PROFILE" \
    > "$REL/archive.log" 2>&1 || { tail -30 "$REL/archive.log" >&2; exit 1; }

cat > "$REL/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key><string>export</string>
    <key>method</key><string>app-store-connect</string>
    <key>signingStyle</key><string>manual</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingCertificate</key><string>${SIGNING_CERTIFICATE}</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key><string>${OMI_IOS_PROFILE}</string>
        <key>${BUNDLE_ID}.watchkitapp</key><string>${OMI_WATCH_PROFILE}</string>
        <key>${BUNDLE_ID}.watchkitapp.widgets</key><string>${OMI_COMPLICATION_PROFILE}</string>
        <key>${BUNDLE_ID}.liveactivity</key><string>${OMI_LIVE_ACTIVITY_PROFILE}</string>
    </dict>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$REL/OmiNotes.xcarchive" -exportPath "$REL/export" \
    -exportOptionsPlist "$REL/ExportOptions.plist" > "$REL/export.log" 2>&1 || { tail -30 "$REL/export.log" >&2; exit 1; }

# The IPA: version, the four signed bundles and their ids, and the Live Activity declared.
IPA="$REL/export/OmiNotes.ipa"
rm -rf "$REL/ipa-check" && mkdir -p "$REL/ipa-check" && unzip -q "$IPA" -d "$REL/ipa-check"
APP="$REL/ipa-check/Payload/OmiNotes.app"
check() { [[ $2 == "$3" ]] || { echo "IPA check failed: $1 is '$2', expected '$3'" >&2; exit 1; }; }
id() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Info.plist"; }
check "app version" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist"))" "$VERSION ($OMI_BUILD_NUMBER)"
check "app id" "$(id "$APP")" "$BUNDLE_ID"
check "Watch app id" "$(id "$APP/Watch/OmiNotesWatch.app")" "$BUNDLE_ID.watchkitapp"
check "complication id" "$(id "$APP/Watch/OmiNotesWatch.app/PlugIns/OmiNotesComplication.appex")" "$BUNDLE_ID.watchkitapp.widgets"
check "Live Activity id" "$(id "$APP/PlugIns/OmiNotesLiveActivity.appex")" "$BUNDLE_ID.liveactivity"
check "NSSupportsLiveActivities" "$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsLiveActivities' "$APP/Info.plist")" "true"
for b in "$APP" "$APP/Watch/OmiNotesWatch.app" "$APP/Watch/OmiNotesWatch.app/PlugIns/OmiNotesComplication.appex" "$APP/PlugIns/OmiNotesLiveActivity.appex"; do
    codesign --verify --deep --strict "$b" || { echo "IPA check failed: signature of $b" >&2; exit 1; }
done
shasum -a 256 "$IPA" | tee "$REL/ipa-sha256.txt"
echo "IPA checked: $VERSION ($OMI_BUILD_NUMBER), app + Watch app + complication + Live Activity signed."

if [[ $UPLOAD == yes ]]; then
    : "${ASC_KEY_ID:?set ASC_KEY_ID}"; : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
    xcrun altool --upload-package "$IPA" --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --wait \
        2>&1 | tee "$REL/upload.log"
    grep -q "UPLOAD SUCCEEDED" "$REL/upload.log" || { echo "Upload did not succeed (see $REL/upload.log)" >&2; exit 1; }
    echo "Uploaded. After processing (VALID), add the build to a TestFlight group to reach testers."
fi
