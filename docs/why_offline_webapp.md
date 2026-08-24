# Why We Chose an Offline Web App over the Flutter App

**Audience:** engineering / management
**Status:** decision record
**Related page:** Tire Pressure Protocol (BLE GATT layout)

---

## Context

We built two generations of a tire-pressure control client that talks to four
ESP32 boards (one per tire) over Bluetooth Low Energy:

| Generation | Technology | Transport |
|---|---|---|
| v1 | Flutter (Android APK) | Bluetooth Classic SPP on Android, BLE on iOS |
| v2 | **Offline web app (PWA)** | Web Bluetooth (GATT) everywhere |

Both implement the same protocol: one CSV message (`"2.4,3.4,1.2,2.5"` in fixed
FL,FR,RL,RR order) written to every board; each board applies its own slot and
confirms with `ACK:<TIRE_ID>:<bar>`.

This page records why v2 replaces v1 as the delivery format.

## Reasons

### 1. Zero-friction distribution

- The app lives at one HTTPS URL. Install = "Add to Home Screen". Done.
- Updates go live at the next launch (a service-worker cache version bump).
  No rebuilding, no sending APKs around, no store review queues.
- Anyone with the link can use it - no Play Store account, no MDM,
  no sideloading instructions.

### 2. No signing / certificate tax (the iOS killer)

- A Flutter iOS build requires a paid Apple Developer membership ($99/year)
  plus App Store Connect API keys for CI builds, *or* weekly re-signing via
  sideload tools.
- The PWA requires **none of that**. The browser is the runtime.

### 3. One artifact for every platform

- The same HTML file runs on Android Chrome, iPhone (via a Web-BLE wrapper
  such as Bluefy, since Safari lacks Web Bluetooth), and any desktop browser.
- In Flutter we had to maintain two transports behind an abstraction layer
  (Classic SPP for Android, BLE for iOS), i.e. two connection code paths,
  two firmware variants and two sets of platform quirks.

### 4. Simpler firmware

- With every client speaking BLE, all boards flash **one identical sketch**
  regardless of which phone controls them.
- The Bluetooth-Classic SPP firmware exists only because of Android-specific
  convenience; dropping it removed an entire maintenance branch.

### 5. Smaller toolchain and dependency surface

Real problems we hit while building v1, none of which exist in v2:

- a Flutter Bluetooth plugin failing the Gradle build (Kotlin version clash)
- plugin licensing configuration required by newer flutter_blue_plus
- JDK / Android SDK version churn on every machine that builds the APK
- 50+ MB build artifacts vs ~20 KB for the entire web app

The web app's total toolchain is: a text editor and `git push`.

### 6. Offline-first by design

- A service worker caches the full app after the first online launch.
- From then on it behaves like a native app: own home-screen icon, fullscreen,
  no URL bar, fully functional in airplane mode.
- BLE is device-to-device; the internet is needed exactly once, at install -
  the same as downloading any APK.

### 7. Instant iteration

- Fix or feature: edit HTML -> push -> users refresh twice. Minutes,
  not an APK-build-and-redistribute cycle.
- Useful during hardware bring-up, where protocol tweaks were frequent.

## Honest trade-offs (accepted)

| Trade-off | Mitigation |
|---|---|
| iOS Safari has no Web Bluetooth | free Bluefy wrapper app; installed-PWA path is Android-first |
| Browser forgets BT grants on close unless `getDevices()` is supported (Chrome 114+) | app auto-reconnects when supported; otherwise shows remembered boards and relinking is one tap each |
| No background execution | auto-reconnect loop runs while the app is open; board restarts advertising on disconnect |
| GATT notifications proved fragile across esp32 core versions | ACK is done by poll-reading the characteristic value (`ACK:<ID>:<bar>`), which works identically everywhere |
| Slightly less native feel (no widgets/intents) | irrelevant for this single-purpose tool |

## Conclusion

For an internal, single-purpose controller talking to custom hardware, the
web app delivers the same UX as the Flutter APK with dramatically less
distribution friction, no signing costs, one code path instead of two, and a
toolchain consisting of a text editor. The Flutter app remains in the repo as
a reference implementation of the same protocol.
