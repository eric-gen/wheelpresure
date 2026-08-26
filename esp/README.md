# Wielcompressor ESP32 firmware (ESP-IDF 5.4)

Firmware for the tire boards. All boards run the **same** image - which tire
a board controls is chosen in the app on first connect and stored in NVS
(survives power loss). No per-board code edits needed.

## Flash a board

```bash
# one-time: install ESP-IDF 5.4, then open its export environment
idf.py set-target esp32s3
idf.py build flash monitor
```

Serial monitor (115200) shows the assigned tire and live pressure.

## BLE interface

| UUID | Properties | Purpose |
|---|---|---|
| `5f1d16a0-...` | service | shared service all apps look for |
| `5f1d16a1-...` | READ, WRITE | app writes CSV `"2.4,3.4,1.2,2.5"` or `ASSIGN:FR`; value becomes the reply (`ACK:<ID>:<bar>`, `ACK:<ID>:0`, `UNASSIGNED`, `ERR`) |
| `5f1d16a2-...` | READ, NOTIFY | measured pressure as text `"2.31"`, updated every 2 s |

## Files

| File | Purpose |
|---|---|
| `main/pressure_sim.c` | **dummy sensor**: simulates filling towards target + noise. Replace with a real driver implementing `pressure_sim.h` |
| `main/ble.c` | NimBLE host: GATT table, advertising, ASSIGN/NVS, notifications |
| `main/main.c` | boot + periodic publish task |

## Stability features

- Advertising restarts automatically after every disconnect
- Writes are length/range checked; bad input answers `ERR`
- Notifications only go to subscribed connections
- Tire assignment persisted in NVS namespace `tirecfg`
