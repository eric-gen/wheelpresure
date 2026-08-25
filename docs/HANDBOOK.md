# WheelCompressor - Complete Handbook

Everything a newcomer needs to understand, build, flash, and extend this
project. No prior knowledge assumed.

---

## 1. What does this project do?

A vehicle has four tires. Each tire gets its own small electronics board
(an **ESP32** microcontroller) that controls an air compressor valve for that
tire. A phone app tells all boards at once what pressure each tire should
get, e.g. "front-left 2.3 bar, front-right 2.3 bar, rear-left 2.5 bar,
rear-right 2.5 bar".

There are two apps that do exactly the same thing:

| App | Runs on | Where it lives |
|---|---|---|
| Flutter app (`lib/`) | Android (APK) / iOS | installable app |
| Web app (`phone_app/`) | any modern browser | https://eric-gen.github.io/wheelpresure/ |

Both speak to the same firmware on the boards.

## 2. How the pieces talk (the protocol)

- The phone sends ONE text message to every connected board:
  `2.4,3.4,1.2,2.5`  (= FL,FR,RL,RR pressures in bar, fixed order)
- Each board knows its own identity (`TIRE_ID`, set when flashing) and only
  applies its own slot in the list.
- Each board confirms by making its characteristic value read
  `ACK:RL:2.5` (= "ACK", my id, the value I applied).
- If no confirmation arrives within ~1.5 seconds, the app shows a red
  warning banner and (Flutter) reverts the tile to the old value.

### Bluetooth details

- Boards advertise as `TireESP32-FL` ... `TireESP32-RR` (BLE).
- Service UUID:  `5f1d16a0-046d-47fd-b49a-d6f1ae118f52`
- Characteristic UUID: `5f1d16a1-046d-47fd-b49a-d6f1ae118f52`
  (properties: READ + WRITE; the ACK works by reading back this value)
- Pressure range: 1.0 - 4.0 bar.

Full wire-level detail: see `docs/tire_pressure_protocol.md`.

## 3. Repository layout

```
flutter_application_1/          <-- everything lives in here
├── lib/                        Flutter app source code
│   ├── main.dart               UI (car view, tiles, editor screen)
│   ├── link.dart               interface + which transport is used
│   ├── ble.dart                Bluetooth LE connection logic
│   └── classic_manager.dart    old Bluetooth-Classic code (unused, kept)
├── esp32/
│   └── tire_pressure_esp32s3/  Arduino sketch flashed onto every board
├── phone_app/                  web app master copy (index.html + icons)
├── docs/                       documentation AND the live web app copy
│   ├── index.html, sw.js...    (GitHub Pages serves this folder!)
│   └── why_offline_webapp.md   why the web app exists
├── ios/                        iOS project (built with Xcode on a Mac)
└── android/                    Android project (Gradle builds it for you)
```

## 4. Building the Android app (Windows)

One-time setup:

1. Install [Flutter](https://docs.flutter.dev/get-started/install/windows)
2. Install Android Studio (gives you the SDK + Java)
3. Run `flutter doctor` in a terminal and fix what it complains about

Every build:

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
cd flutter_application_1
flutter build apk --debug
```

Result: `build\app\outputs\flutter-apk\app-debug.apk`
(copy it to a phone and open it, or `adb install -r <path>`).

With a phone connected via USB (or wireless adb), `flutter run` gives you
hot reload while developing.

## 5. Building the iOS app (needs a Mac)

See `docs/MAC_IOS_BUILD.md`. Short version: Xcode + CocoaPods,
then `flutter run` with an iPhone plugged in.
Free Apple ID = runs on your own device for 7 days.
TestFlight/App Store requires the paid Apple developer program ($99/year).

## 6. Updating the web app

The web app is plain HTML/JS - no build step:

1. Edit `phone_app/index.html`
2. **Important**: bump BOTH version markers so phones pick up the change:
   - `APP_VERSION` constant near the top of the `<script>` block
   - the cache name in `phone_app/sw.js` (e.g. `tire-pwa-v14` -> `-v15`)
3. Copy everything from `phone_app/` into `docs/`
4. Commit and push to GitHub
5. Installed apps update themselves on their next online launch

## 7. Flashing a board (Arduino IDE)

1. Install the Arduino IDE and the "esp32 by Espressif Systems" board package
2. Open `esp32/tire_pressure_esp32s3/tire_pressure_esp32s3.ino`
3. Set `#define TIRE_ID "FL"` (or FR/RL/RR) for THAT board - every board
   gets its own value!
4. Board settings: "ESP32S3 Dev Module", USB CDC On Boot: Enabled
5. Flash, open Serial Monitor at 115200 baud. You should see:
   `Advertising as 'TireESP32-FL' - waiting for the app...`

## 8. Debugging cheatsheet

**Where do app logs go?**
`adb logcat` shows lines starting with `I flutter :` - all BLE decisions are
logged there (scan results, connects, acks, reconnect attempts).

**Board receives nothing?**
Check serial monitor: does it print `App connected`? Then check what it
prints after a send (`pressure received` / `ACK ready`).

**Scan finds zero devices (Samsung)?**
Location permission AND Location service must be on; the app requests both.
If scans still die instantly (<1 s), that was the old FBP timeout bug -
keep using the manual scan lifecycle currently in `lib/ble.dart`.

**Web app cannot find the board?**
iOS Safari has NO Web Bluetooth - use the free "Bluefy" app there.
Chrome flags `#enable-experimental-web-platform-features` and
`#enable-web-bluetooth-new-permissions-backend` unlock automatic
reconnect-after-restart on Android.

**Android connect error 133?**
Stale GATT handle; the app already clears it before retrying. If it keeps
happening for one specific board, power-cycle that board.

## 9. Golden rules for changes

- Never break the CSV message order (FL,FR,RL,RR) - boards depend on it
- Keep `phone_app/` and `docs/` copies identical
- Bump versions (see section 6) or users keep running old code
- Test with at least one real board before pushing; the ACK/read-back
  behavior is the contract between app and firmware
