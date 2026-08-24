# Tire Pressure Control - Communication Protocol

*Ready-to-paste Confluence page. In the Confluence editor use Insert > Markup (or paste directly); tables and headings convert automatically.*

## 1. Overview

A Flutter phone app controls the target tire pressures of a vehicle.
Each wheel has its own ESP32 board. The app sends **one message containing all
four target pressures**; every board picks out the slot that belongs to its own
tire and ignores the rest.

```
                 +---------------------+
   SET ALL / OK  |   Phone app         |
 --------------> | (Flutter, Android)  |
                 +----------+----------+
                            |  "2.4,3.4,1.2,2.5"
        +-------------------+-------------------+
        v                   v                   v
  +-----------+       +-----------+       +-----------+
  | ESP32 FL  |       | ESP32 FR  |  ...  | ESP32 RR  |
  | TIRE_ID=FL|       | TIRE_ID=FR|       | TIRE_ID=RR|
  +-----------+       +-----------+       +-----------+
```

## 2. Tire slots and device naming

| Order | Slot key | Tire        | Advertised / paired name |
|-------|----------|-------------|--------------------------|
| 0     | FL       | front left  | `TireESP32-FL`           |
| 1     | FR       | front right | `TireESP32-FR`           |
| 2     | RL       | rear left   | `TireESP32-RL`           |
| 3     | RR       | rear right  | `TireESP32-RR`           |

Each board is flashed with its own `#define TIRE_ID` (`"FL"`, `"FR"`, `"RL"`
or `"RR"`). The app identifies boards purely by this name suffix.

## 3. Payload format (shared by all transports)

* Comma separated, fixed order `FL,FR,RL,RR`, one decimal place:

```
2.4,3.4,1.2,2.5
```

* Value range: 1.0 - 4.0 bar (enforced by the app slider).
* Sent after every confirmation (single-tire edit **or** SET ALL) so boards can
  never drift apart.
* A board applies only `parts[TIRE_ID]`; all other fields are ignored.

## 4. Transport A - Bluetooth LE GATT (ESP32-S3)

> Note: the ESP32-S3 supports BLE only (no Bluetooth Classic).

### GATT layout

```
GATT server "TireESP32-<ID>"
|
+-- Service  UUID 5F1D16A0-046D-47FD-B49A-D6F1AE118F52   "Tire Pressure Service"
    |
    +-- Characteristic  UUID 5F1D16A1-046D-47FD-B49A-D6F1AE118F52
        Name         "Pressure Command"
        Properties   WRITE (write-with-response)
        Max len      20 bytes  (longest payload "4.0,4.0,4.0,4.0" = 15 bytes)
        Value        UTF-8 CSV string, see section 3
```

| Item               | Value                                        |
|--------------------|----------------------------------------------|
| Service UUID       | `5f1d16a0-046d-47fd-b49a-d6f1ae118f52`       |
| Characteristic UUID| `5f1d16a1-046d-47fd-b49a-d6f1ae118f52`       |
| Properties         | WRITE (response required)                    |
| Access             | Write-only, no read/notify needed today      |
| Shared by          | All four boards (identical layout per board) |

### Connection flow (app side)

1. Runtime permissions: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
   (`neverForLocation` flag on scan).
2. Unfiltered BLE scan (8 s) - boards matched by name suffix `-FL` .. `-RR`.
3. Sequential `connect()` + service discovery to **every** board found;
   the shared characteristic is cached per board.
4. Writes go to all connected boards; connection-state listener drops dead
   links from the UI.

### Firmware

* Sketch: `esp32/tire_pressure_esp32s3/tire_pressure_esp32s3.ino`
* Arduino board: *ESP32S3 Dev Module*, USB CDC On Boot: *Enabled*
* Advertising restarts automatically after any disconnect.

## 5. Transport B - Bluetooth Classic SPP (ESP32-WROVER-E) - *current*

> The original ESP32 chip (WROVER-E etc.) adds Bluetooth Classic; profile used:
> Serial Port Profile (SPP).

| Item            | Value                                            |
|-----------------|--------------------------------------------------|
| Profile         | SPP (RFCOMM), service UUID `00001101-...`        |
| Discovery       | Android **paired devices** only (pair once)      |
| Line ending     | `\n` terminates each message                     |
| Multi-board     | Several simultaneous RFCOMM connections          |
| Reconnect       | Auto-retry every 5 s per lost board              |

### Connection flow (app side)

1. Pair every board once via Android Bluetooth settings.
2. App lists bonded devices, filters names starting with `TireESP32`.
3. Opens an RFCOMM/SPP connection to **all** of them in parallel.
4. Locked UX: a tire is only editable while its board is linked; SET ALL
   requires all four.

### Firmware

* Sketch: `esp32/tire_spp_esp32wrover/tire_spp_esp32wrover.ino`
* Arduino board: *ESP32 Wrover Module* (or *ESP32 Dev Module*)
* **Not compatible with ESP32-S3** (no classic radio).

## 6. Serial debug output (both variants)

| Event                | Output                                          |
|----------------------|-------------------------------------------------|
| Boot                 | `=== Tire FL - Pressure BLE Server ===` / `=== Tire FL - Pressure SPP Server ===` |
| Message received     | `[SPP] FL pressure received: 2.4 bar`           |
| Wrong-slot data      | unexpected message warning (board ignores it)   |
| Disconnect (BLE)     | `App disconnected - advertising again`          |
