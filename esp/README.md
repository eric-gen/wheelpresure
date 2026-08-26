# Wielcompressor ESP32 firmware (ESP-IDF 5.4)

Firmware for the tire boards. All boards run the **same** image - which tire
a board controls is chosen in the app on first connect and stored in NVS
(survives power loss). No per-board code edits needed.

## Flash a board

```bash
idf.py set-target esp32s3
idf.py build flash monitor
```

Serial monitor (115200) shows the assigned tire and live pressure.

### ESP-IDF setup explained (Windows)

`idf.py` is the build/flash tool that ships with **ESP-IDF** - it does not
exist on your PC until you install and "activate" IDF. The activation step
matters: every Command Prompt must know where the compiler, Python tools and
IDF scripts live before `idf.py` works.

One-time install:

1. Download the **ESP-IDF 5.4 Windows Installer** from Espressif
   (espressif.com -> Software -> ESP-IDF, pick the v5.4 offline installer).
2. Run it. It installs:
   - the framework itself (default: `C:\Espressif\frameworks\esp-idf-v5.4`)
   - the Xtensa compiler toolchain, CMake, Ninja, a bundled Python
   - a desktop shortcut called **"ESP-IDF 5.4 CMD"**
3. That shortcut opens a Command Prompt with everything pre-configured.
   This is the environment you must use - a plain `cmd` will NOT find
   `idf.py`.

Every-day workflow:

```bat
:: open "ESP-IDF 5.4 CMD" from the start menu, then:
cd /d C:\Users\Benjamin\Documents\wiel_compresor_app_flutter\wielcompressor\esp\tire_idf
idf.py set-target esp32s3     :: only needed once per project folder
idf.py build                  :: compiles (first build takes minutes)
idf.py flash monitor          :: flashes over USB + opens serial log
```

If you already had a terminal open you can activate it manually instead of
using the shortcut:

```bat
C:\Espressif\frameworks\esp-idf-v5.4\export.bat
```

Useful variations:

| Command | Meaning |
|---|---|
| `idf.py -p COM5 flash` | flash via a specific COM port (see Device Manager) |
| `idf.py -DTIRE_ID=FL build` | bake an optional factory tire into the image |
| `idf.py fullclean` | wipe all build output when things act strange |
| `Ctrl+]` | exit the serial monitor |

Troubleshooting:

- `'idf.py' is not recognized` -> you are in a normal CMD; open the
  ESP-IDF CMD shortcut or run `export.bat` first.
- Installer errors about Windows features: enable **Developer Mode**
  (Settings > Privacy & security > For developers) and long paths
  (`git config --global core.longpaths true` is not needed for IDF, but the
  installer may ask for symlink support).

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
