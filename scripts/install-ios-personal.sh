#!/bin/sh
# Personal Team builds omit paid Hotspot Configuration and App Groups.
set -eu
cd "$(dirname "$0")/.."
device_id=${1:?Usage: sh scripts/install-ios-personal.sh DEVICE_ID TEAM_ID}
team_id=${2:?Usage: sh scripts/install-ios-personal.sh DEVICE_ID TEAM_ID}
flutter pub get
flutter build ios --config-only --release --no-codesign
(cd ios && pod install)
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination "id=$device_id" -derivedDataPath build/ios-personal \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CODE_SIGN_ENTITLEMENTS=Runner/PersonalTeam.entitlements \
  CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$team_id" -quiet
xcrun devicectl device install app --device "$device_id" build/ios-personal/Build/Products/Release-iphoneos/Runner.app
xcrun devicectl device process launch --device "$device_id" --terminate-existing com.b1101.tark
