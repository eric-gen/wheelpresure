# Building the iOS app on a MacBook

The project is fully prepared - everything below happens **on the Mac**.

## One-time Mac setup

1. Install Xcode from the App Store (and open it once, accept licenses)
2. Xcode > Settings > Locations: select the newest Command Line Tools
3. Install CocoaPods: `sudo gem install cocoapods`
4. Install Flutter (or copy this repo and use fvm/whatever) - any recent stable
5. `flutter doctor` - fix anything it flags under the iOS section

## Build & run

```bash
git clone https://github.com/eric-gen/wheelpresure.git
cd wheelpresure/flutter_application_1   # app lives in this subfolder
flutter pub get
cd ios && pod install && cd ..
flutter run                              # with iPhone plugged in, or:
open ios/Runner.xcworkspace              # then press Run in Xcode
```

Note: always open **Runner.xcworkspace** (not .xcodeproj) once pods exist.

## Signing

- Open `ios/Runner.xcworkspace` > Runner target > Signing & Capabilities
- Tick "Automatically manage signing", pick your Team
  - Free Apple ID works for on-device runs (7-day expiry)
  - Paid developer account ($99/yr) needed only for TestFlight/App Store

Bundle id is already set to `com.vaengineering.tirepressure` (change it in
the same screen if you want something else).

## Already done in the repo

- Bluetooth usage descriptions in Info.plist (`NSBluetoothAlwaysUsageDescription`)
- Podfile present (iOS 13.0 minimum)
- App uses only BLE via flutter_blue_plus - no special capabilities needed
- Same protocol as Android: CSV write + read-back ACK per board

## Gotchas

- If `pod install` complains about Generated.xcconfig: run `flutter pub get`
  first (from the app folder).
- First Xcode build downloads ~1 GB of pods/frameworks; be patient.
- On-device run needs "Trust this computer" on the iPhone + Developer Mode
  enabled (Settings > Privacy & Security > Developer Mode, iOS 16+).
