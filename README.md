# Wielcompressor

Control the tire pressure of a vehicle from your phone. One ESP32 board per
tire (FL / FR / RL / RR) receives target pressures over Bluetooth LE and
reports back live measurements.

## Repository layout

```
wielcompressor/
├── app/     <- the Flutter phone app (Android + iOS)
├── esp/     <- ESP32 firmware (ESP-IDF 5.4)
└── docs/    <- documentation + the deployed web app (GitHub Pages)
```

## Documentation

| Document | What it covers |
|---|---|
| [`docs/HANDBOOK.md`](docs/HANDBOOK.md) | **Start here** - full walkthrough for newcomers |
| [`app/README.md`](app/README.md) | Building & running the Flutter app |
| [`esp/README.md`](esp/README.md) | Flashing & configuring the ESP32 boards |
| [`docs/tire_pressure_protocol.md`](docs/tire_pressure_protocol.md) | BLE wire protocol |
| [`docs/why_offline_webapp.md`](docs/why_offline_webapp.md) | About the companion web app |

## The 60-second version

1. Flash each ESP32 with `esp/tire_idf` (all boards get identical firmware).
2. Open the app -> tap the sensors icon -> connect to a board.
3. The first time, the app asks which tire that board is. Done forever -
   both the phone and the board remember.
4. Set pressures on the main screen; boards confirm and report live values.

## Web app

A browser version (no install) lives at
https://eric-gen.github.io/wheelpresure/ - same protocol, runs fully offline
after first load. Source: `docs/index.html`.
