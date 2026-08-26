# WheelCompressor - Complete Handbook

Everything a newcomer needs to understand, build, flash, and extend this
project. No prior knowledge assumed.

---

## 1. What does this project do?

A vehicle has four tires. Each tire gets its own small electronics board
(an **ESP32**) that controls an air compressor valve for that tire. A phone
app tells all boards at once what pressure each tire should get, e.g.
"FL 2.3 bar, FR 2.3 bar, RL 2.5 bar, RR 2.5 bar", and the boards report back
their live measured pressure.

There are two apps that do the same thing:

| App | Runs on | Where it lives |
|---|---|---|
| Flutter app (`app/`) | Android (APK) / iOS | installable app |
| Web app (`docs/index.html`) | any modern browser | https://eric-gen.github.io/wheelpresure/ |

## 2. Repository layout

```
wielcompressor/            <- repository root
├── app/                   Flutter phone app
│   └── lib/               Dart source (main.dart, ble.dart, devices_screen.dart...)
├── esp/
│   └── tire_idf/          ESP-IDF 5.4 firmware project (all boards)
└── docs/                  documentation + deployed web app (GitHub Pages)
```

## 3. How the pieces talk (the protocol)

- Boards advertise as `TireESP32-XXXX` (XXXX = unique hardware suffix).
- The phone sends ONE text message to every connected board:
  `2.4,3.4,1.2,2.5` (= FL,FR,RL,RR in bar, fixed order).
- Each board knows its own assigned tire and only applies its own slot.
- Each board confirms by making its characteristic value read
  `ACK:RL:2.5`.
- New boards are **assigned** to a tire on first connect:
  the phone sends `ASSIGN:FR`, stores the choice locally AND the board
  stores it in NVS. This happens once per board, ever.
- Boards also publish their live measured pressure (~every 2 s) on a
  second characteristic, which the app displays on each tile.
- No confirmation within ~1.5 s -> red warning banner + value rollback.

### BLE details

- Service UUID:  `5f1d16a0-046d-47fd-b49a-d6f1ae118f52`
- Command char:  `5f1d16a1-...` (READ + WRITE - targets, ACKs, assignment)
- Pressure char: `5f1d16a2-...` (READ + NOTIFY - live measurement)
- Pressure range: 1.0 - 4.0 bar

Full wire-level detail: `docs/tire_pressure_protocol.md`.

## 4. Building the Android app (Windows)

One-time setup:

1. Install [Flutter](https://docs.flutter.dev/get-started/install/windows)
2. Install Android Studio (SDK + Java)
3. `flutter doctor` and fix what it complains about

Every build:

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
cd wielcompressor\app
flutter pub get
flutter build apk --release --split-per-abi
```

Install the APK matching your phone (modern Samsungs: `app-arm64-v8a-release.apk`).
`flutter run` with a connected phone gives hot reload while developing.

## 5. Building the iOS app (needs a Mac)

See `docs/MAC_IOS_BUILD.md`. Free Apple ID runs builds on your own device
for 7 days; TestFlight/App Store requires the paid developer program.

## 6. Flashing a board (ESP-IDF 5.4)

All boards run identical firmware - no code edits needed:

```bash
cd wielcompressor/esp/tire_idf
idf.py set-target esp32s3
idf.py build flash monitor
```

Which tire a board controls is chosen **in the app** on first connect and
stored in NVS on the board itself. Serial monitor (115200) shows the current
assignment and measurements.

## 7. Debugging cheatsheet

**App logs**: `adb logcat` lines starting with `I flutter :` show every scan,
connect, ack, and reconnect decision.

**Board logs**: Arduino-style serial monitor at 115200 via `idf.py monitor`.

**Scan finds nothing (Samsung)?**
Location permission AND Location service must be on. Scans use a manual
lifecycle (see `ble.dart`) because Samsung aborts FBP's timeout parameter.

**Android error 133 on connect?**
Stale GATT handle. The app clears it before retrying; power-cycle a board
if one keeps failing.

**Web app notes**
iOS Safari has no Web Bluetooth - use the free Bluefy app there. Chrome
flags `#enable-experimental-web-platform-features` +
`#enable-web-bluetooth-new-permissions-backend` enable auto-reconnect
across browser restarts.

## 8. Golden rules

- Never break the CSV order FL,FR,RL,RR - boards depend on it
- Keep `phone_app/` (web master) and `docs/` (deployed copy) in sync, and
  bump the version markers when changing the web app
- The ACK/read-back behavior is the contract between app and firmware -
  change both sides together or not at all
