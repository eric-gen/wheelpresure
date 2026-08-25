# WheelCompressor

Phone app + web app that control one ESP32 board per tire (FL/FR/RL/RR)
over Bluetooth LE. Boards receive pressures as one CSV message
(`2.4,3.4,1.2,2.5`) and confirm with `ACK:<TIRE_ID>:<bar>`.

- **New to the project?** Read [`docs/HANDBOOK.md`](docs/HANDBOOK.md) first.
- **Wire-level protocol**: [`docs/tire_pressure_protocol.md`](docs/tire_pressure_protocol.md)
- **Why a web app exists**: [`docs/why_offline_webapp.md`](docs/why_offline_webapp.md)
- **iOS build**: [`docs/MAC_IOS_BUILD.md`](docs/MAC_IOS_BUILD.md)

| Deliverable | Location | Notes |
|---|---|---|
| Flutter app | `flutter_application_1/lib` | Android APK; iOS via Xcode |
| Web app (PWA) | `phone_app/` -> deployed from `docs/` | https://eric-gen.github.io/wheelpresure/ |
| Board firmware | `flutter_application_1/esp32/tire_pressure_esp32s3` | Arduino sketch, set TIRE_ID per board |

Quick Android build:

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
cd flutter_application_1
flutter build apk --debug
```
