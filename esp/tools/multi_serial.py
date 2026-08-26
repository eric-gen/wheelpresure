#!/usr/bin/env python3
"""
Multi-board serial monitor - watch all ESP32 boards in one window.

Every line is prefixed with the port name and colored per board, e.g.:

    [COM11] I (1234) tire: measured 2.47 bar      <- cyan
    [COM14] I (1234) tire: phone connected        <- green

Special lines are highlighted:
    green   = connections / ACKs / assignments (good news)
    red     = errors, disconnects, rejections (bad news)
    yellow  = warnings and retries
    gray    = boot noise (ESP-ROM, load:0x..., etc.)

Usage:
    python multi_serial.py                 # auto-detect all COM ports
    python multi_serial.py COM11 COM14     # only these ports
    python multi_serial.py --no-color      # plain output (for log files)

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


def detect_ports() -> list[str]:
    """All COM ports present on this PC."""
    return sorted(p.device for p in list_ports.comports())

# ---- ANSI colors ----------------------------------------------------------
RESET = "\033[0m"
DIM = "\033[2m"
COLORS = ["\033[96m", "\033[92m", "\033[95m", "\033[93m",
          "\033[94m", "\033[91m", "\033[97m", "\033[36m"]
USE_COLOR = "--no-color" not in sys.argv


def paint(text: str, color: str) -> str:
    return f"{color}{text}{RESET}" if USE_COLOR else text


def colorize_line(line: str) -> str:
    """Give notable lines a meaning-based highlight."""
    low = line.lower()
    if any(k in low for k in ("error", "fail", "rejected", "disconnected",
                              "err:", "abort", "guru meditation")):
        return paint(line, "\033[91m")                       # red
    if any(k in low for k in ("ack:", "assigned", "phone connected",
                              "accepted")):
        return paint(line, "\033[92m")                       # green
    if any(k in low for k in ("warn", "retrying", "reconnect", "unassigned")):
        return paint(line, "\033[93m")                       # yellow
    if low.startswith(("esp-rom", "rst:", "load:", "entry ", "boot:",
                       "spiwp", "mode:", "saved pc")) or "0x" in low[:12]:
        return DIM + line + RESET                            # gray boot noise
    return line


class BoardReader(threading.Thread):
    """Reads one COM port forever and prints its lines with a label."""

    LABELS = ["FL", "FR", "RL", "RR"]  # first boards get friendly names

    def __init__(self, index: int, port: str):
        super().__init__(daemon=True)
        self.port = port
        self.friendly = (BoardReader.LABELS[index]
                         if index < len(BoardReader.LABELS) else str(index + 1))
        self.prefix = f"[{port} {self.friendly}]"
        self.color = COLORS[index % len(COLORS)]
        self.stop_flag = threading.Event()

    def out(self, line: str):
        tag = paint(f"{self.prefix:<16}", self.color)
        print(f"{tag} {colorize_line(line)}", flush=True)

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
                            line, partial = partial.split("\n", 1)
                            if line.strip("\r"):
                                self.out(line.rstrip())
            except (serial.SerialException, OSError):
                self.out(paint("--- port gone, retrying... ---", "\033[93m"))
                time.sleep(2)


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
    print(f"Monitoring {len(ports)} board(s): {header}")
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
