#!/usr/bin/env python3
"""
Multi-board serial monitor - watch all ESP32 boards in one window.

Default view (clean):
    [COM10 FL] measured 2.46 bar (target 2.3)
    [COM11 FR] ACK:FR:2.3
    [COM14 RL] phone connected

Every board gets its own color - label AND text match.
Use --all to see everything the boards print (NimBLE chatter, boot log...).

Usage:
    python multi_serial.py                  # auto-detect all COM ports
    python multi_serial.py COM11 COM14      # only these ports
    python multi_serial.py --all            # show every line
    python multi_serial.py --no-color       # plain output (for log files)

Requires:  pip install pyserial
Stop with: Ctrl+C
"""

import sys
import threading
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print("pyserial missing:  pip install pyserial")
    sys.exit(1)

BAUD = 115200

# ---- ANSI colors ----------------------------------------------------------
RESET = "\033[0m"
DIM = "\033[2m"
BOARD_COLORS = ["\033[96m", "\033[92m", "\033[95m", "\033[93m",
                "\033[94m", "\033[91m", "\033[97m", "\033[36m"]
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"

USE_COLOR = "--no-color" not in sys.argv
SHOW_ALL = "--all" in sys.argv


def paint(text: str, color: str) -> str:
    return f"{color}{text}{RESET}" if USE_COLOR else text


def semantic_color(line: str) -> str | None:
    """Color for special lines; None = no special meaning."""
    low = line.lower()
    if any(k in low for k in ("error", "fail", "rejected", "err:",
                              "abort", "guru meditation")):
        return RED
    if any(k in low for k in ("ack:", "assigned", "phone connected",
                              "accepted")):
        return GREEN
    if any(k in low for k in ("warn", "retrying", "reconnect", "unassigned",
                              "disconnected")):
        return YELLOW
    return None


def is_noise(line: str) -> bool:
    """Boot garbage and NimBLE chatter we hide by default."""
    low = line.lower()
    starts = ("esp-rom", "rst:", "load:", "entry ", "boot:", "spiwp",
              "mode:", "saved pc", "elf file sha")
    if any(low.startswith(s) for s in starts):
        return True
    return any(k in low for k in ("nimble:", "att_handle", "gatt procedure",
                                  "ble_init", "phy_init", "cpu_start",
                                  "heap_init", "partition table",
                                  "esp_image", "spi_flash", "sleep_gpio",
                                  "main_task", "nvs_sec", "efuse_init",
                                  "app_init", "boot:", "serial_clockvote",
                                  "ibs_", "device_wakeup"))


class BoardReader(threading.Thread):
    """Reads one COM port forever and prints its lines with a label."""

    LABELS = ["FL", "FR", "RL", "RR"]  # first boards get friendly names

    def __init__(self, index: int, port: str):
        super().__init__(daemon=True)
        self.port = port
        self.friendly = (BoardReader.LABELS[index]
                         if index < len(BoardReader.LABELS) else str(index + 1))
        self.prefix = f"[{port} {self.friendly}]"
        self.color = BOARD_COLORS[index % len(BOARD_COLORS)]
        self.stop_flag = threading.Event()

    def out(self, line: str):
        tag = paint(f"{self.prefix:<16}", self.color)
        sem = semantic_color(line)
        body = paint(line, sem) if sem else paint(line, self.color)
        print(f"{tag} {body}", flush=True)

    def run(self):
        while not self.stop_flag.is_set():
            try:
                with serial.Serial(self.port, BAUD, timeout=1) as ser:
                    self.out("--- opened ---")
                    partial = ""
                    while not self.stop_flag.is_set():
                        chunk = ser.read(256).decode("utf-8", errors="replace")
                        if not chunk:
                            continue
                        partial += chunk
                        while "\n" in partial:
                            raw, partial = partial.split("\n", 1)
                            raw = raw.rstrip()
                            if not raw:
                                continue
                            low = raw.lower()
                            interesting = (
                                SHOW_ALL
                                or "measured" in low
                                or "target" in low
                                or semantic_color(raw) is not None
                            )
                            if is_noise(raw):
                                continue
                            if interesting or SHOW_ALL:
                                self.out(raw)
            except (serial.SerialException, OSError):
                self.out(paint("--- port gone, retrying... ---", YELLOW))
                time.sleep(2)


def detect_ports() -> list[str]:
    """All COM ports present on this PC."""
    return sorted(p.device for p in list_ports.comports())


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    ports = args if args else detect_ports()
    if not ports:
        print("No COM ports found. Plug in the boards or pass them explicitly:")
        print("  python multi_serial.py COM11 COM14")
        return

    readers = [BoardReader(i, p) for i, p in enumerate(ports)]
    for r in readers:
        r.start()

    header = ", ".join(f"{r.port} -> {r.friendly}" for r in readers)
    mode = "everything" if SHOW_ALL else "pressures + events only"
    print(f"Monitoring {len(ports)} board(s) ({mode}): {header}")
    print("Ctrl+C to stop\n")

    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\nStopping...")
        for r in readers:
            r.stop_flag.set()


if __name__ == "__main__":
    main()
