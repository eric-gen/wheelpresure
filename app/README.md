# Wielcompressor app (Flutter)

Phone app for the tire pressure system. Works on Android (APK) and iOS.

## Features

- Car overview with four tires; live measured pressure per tire
- Set individual tires or all at once; boards confirm every command,
  unconfirmed values roll back automatically and show a warning banner
- Devices screen: scan, connect/disconnect each board, and assign a board
  to a tire on first use (stored on phone + board, survives restarts)
- Automatic reconnection when a board drops out

## Build (Android)

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
cd app
flutter pub get
flutter build apk --release --split-per-abi
# -> build\app\outputs\flutter-apk\app-arm64-v8a-release.apk (~16 MB)
```

For daily development `flutter run` with a phone connected gives hot reload.
iOS instructions: see `../docs/MAC_IOS_BUILD.md`.

## Source layout

| File | Purpose |
|---|---|
| `lib/main.dart` | Overview UI (car view, tiles, editor screen) |
| `lib/devices_screen.dart` | Board scan / connect / tire-assignment screen |
| `lib/ble.dart` | All Bluetooth LE logic (scan, link, ACKs, reconnect) |
| `lib/link.dart` | Transport interface + platform selection |
| `lib/toast.dart` | Single-slot toast notifications |

## First run

1. Grant Location + Nearby devices permissions when asked
2. Tap the sensors icon (top right) -> scan -> Connect next to a board
3. A card appears asking which tire that board is - pick FL/FR/RL/RR
4. Repeat per board; from then on everything reconnects automatically
