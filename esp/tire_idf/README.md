# Tire board firmware - ESP-IDF 5.4 (NimBLE)

Replacement for the Arduino sketch, same BLE protocol plus a new live
pressure characteristic.

## Build & flash

```bash
# one-time: install ESP-IDF 5.4 and run its export script
idf.py set-target esp32s3
idf.py -DTIRE_ID=FL build flash monitor   # FL / FR / RL / RR per board
```

`TIRE_ID` can also be baked in by editing `main/CMakeLists.txt`.

## BLE layout

| UUID | Properties | Purpose |
|---|---|---|
| `5f1d16a0-...` | service | same service the apps already use |
| `5f1d16a1-...` | READ, WRITE | app writes CSV `"2.4,3.4,1.2,2.5"`, value becomes `ACK:<ID>:<bar>` |
| `5f1d16a2-...` | READ, NOTIFY | live measured pressure as text `"2.31"` |

## Where things live

- `main/pressure_sim.c` - **dummy sensor**. Simulates filling towards the
  requested target with realistic noise. Replace this file with a real
  sensor driver implementing `pressure_sim.h` and nothing else changes.
- `main/ble.c` - NimBLE host, GATT table, advertising/reconnect handling.
- `main/main.c` - boot + 2 s publish task.

## Stability notes

- Advertising restarts automatically after every disconnect
- Notifications only go to subscribed connections; stale sends are dropped
- Writes are length- and range-checked; bad payloads return `ERR`
- Single connection at a time (one phone controls all four boards anyway)
