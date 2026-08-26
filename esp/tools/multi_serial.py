#!/usr/bin/env python3
"""
Multi-board serial monitor.

Prints output of every connected ESP32 with a port prefix:

    [COM11] I (1234) tire: measured 2.47 bar
    [COM14] I (1234) tire: phone connected

Usage:
    python multi_serial.py                 # auto-detect all COM ports
    python multi_serial.py COM11 COM14     # only these ports
    python multi_serial.py -b 115200       # custom baud (default 115200)

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
    """All COM ports that look like serial devices."""
    return sorted(p.device for p in list_ports.comports())


class BoardReader(threading.Thread):
    def __init__(self, port: str):
        super().__init__(daemon=True)
        self.port = port
        self.prefix = f"[{port}]"
        self.stop_flag = threading.Event()

    def run(self):
        while not self.stop_flag.is_set():
            try:
                with serial.Serial(self.port, BAUD, timeout=1) as ser:
                    print(f"{self.prefix} --- opened ---", flush=True)
                    partial = ""
                    while not self.stop_flag.is_set():
                        chunk = ser.read(256).decode("utf-8", errors="replace")
                        if not chunk:
                            continue
                        partial += chunk
                        while "\n" in partial:
                            line, partial = partial.split("\n", 1)
                            line = line.rstrip("\r")
                            if line:
                                print(f"{self.prefix} {line}", flush=True)
            except (serial.SerialException, OSError):
                print(f"{self.prefix} --- port gone, retrying... ---",
                      flush=True)
                time.sleep(2)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    ports = args if args else detect_ports()
    if not ports:
        print("No COM ports found. Plug in the boards or pass them explicitly.")
        return

    readers = []
    for p in ports:
        r = BoardReader(p)
        r.start()
        readers.append(r)

    print(f"Monitoring {len(ports)} port(s): {', '.join(ports)}  (Ctrl+C to stop)\n")
    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\nStopping...")
        for r in readers:
            r.stop_flag.set()


if __name__ == "__main__":
    main()
