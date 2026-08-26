#!/usr/bin/env python3
"""
Erase + flash EVERY connected ESP32-S3 board in one go.

Uses the already-built binaries from ../tire_idf/build/, so run
`idf.py build` once first. Run this script from the ESP-IDF CMD
(so the esptool module is available).

Usage:
    python reflash_all.py               # all detected ESP32 boards
    python reflash_all.py COM10 COM14   # only these ports
    python reflash_all.py --no-erase    # flash only, keep NVS (tire stays)
                                        # default DOES erase (fresh assignment)

Every action is printed with a [COMx] prefix, boards are done in parallel.
"""

import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    from serial.tools import list_ports
except ImportError:
    print("pyserial missing:  pip install pyserial")
    sys.exit(1)

BUILD = Path(__file__).resolve().parents[1] / "tire_idf" / "build"
FLASH_MAP = [
    (0x0,     "bootloader/bootloader.bin"),
    (0x8000,  "partition_table/partition-table.bin"),
    (0x10000, "tire_pressure.bin"),
]
BAUD = 460800

# Espressif USB-JTAG/serial VID, Silicon Labs CP210x UART VID
ESP_VIDS = {0x303A, 0x10C4}


def detect_ports() -> list[str]:
    found = []
    for p in list_ports.comports():
        vid = getattr(p, "vid", None) or 0
        desc = (p.description or "").lower()
        if vid in ESP_VIDS or "cp210" in desc or "uart" in desc or "jtag" in desc:
            found.append(p.device)
    return sorted(found)


def run_esptool(prefix: str, port: str, args: list[str]) -> bool:
    cmd = [sys.executable, "-m", "esptool", "--chip", "esp32s3",
           "-p", port, "-b", str(BAUD),
           "--before", "default_reset", "--after", "hard_reset"] + args
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            errors="replace")
    for line in proc.stdout:                     # type: ignore[union-attr]
        print(f"{prefix} {line.rstrip()}", flush=True)
    return proc.wait() == 0


class Flasher(threading.Thread):
    def __init__(self, port: str, erase: bool):
        super().__init__(daemon=True)
        self.port = port
        self.erase = erase
        self.prefix = f"[{port}]"
        self.ok = False

    def say(self, msg: str):
        print(f"{self.prefix} {msg}", flush=True)

    def run(self):
        if self.erase:
            self.say("erasing flash (NVS too - tire assignment is wiped)...")
            if not run_esptool(self.prefix, self.port, ["erase_flash"]):
                self.say("ERASE FAILED")
                return
            time.sleep(0.5)

        args = ["write_flash"]
        for offset, rel in FLASH_MAP:
            path = BUILD / rel
            if not path.exists():
                self.say(f"missing {path} - run 'idf.py build' first!")
                return
            args += [hex(offset), str(path)]

        self.say("flashing bootloader + partition table + app...")
        if run_esptool(self.prefix, self.port, args):
            self.say("DONE - board rebooted and ready")
            self.ok = True
        else:
            self.say("FLASH FAILED")


def main():
    erase = "--no-erase" not in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    ports = args if args else detect_ports()
    if not ports:
        print("No boards detected. Plug them in (or pass ports explicitly):")
        print("  python reflash_all.py COM10 COM11 COM14 COM16")
        return

    mode = "erase + flash" if erase else "flash only (NVS kept)"
    print(f"Reflash ({mode}) on {len(ports)} board(s): {', '.join(ports)}\n")

    flashers = [Flasher(p, erase) for p in ports]
    for f in flashers:
        f.start()
    for f in flashers:
        f.join()

    good = sum(1 for f in flashers if f.ok)
    print(f"\nFinished: {good}/{len(flashers)} board(s) flashed successfully.")


if __name__ == "__main__":
    main()
