#!/usr/bin/env python3
"""抓一段串口日志（默认 20 s），用于板侧自检取证。

用法：python3 tools/capture.py [port] [outfile] [seconds]
先打开串口再复位（先 DTR 高 RTS 低拉低，再 RTS 释放），避免丢 ROM banner。
"""
import sys
import time

import serial


def main() -> int:
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB1"
    out = sys.argv[2] if len(sys.argv) > 2 else "logs/capture.log"
    seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0
    s = serial.Serial(port, 115200, timeout=0.2)
    try:
        s.setDTR(False)
        s.setRTS(True)
        time.sleep(0.1)
        s.setRTS(False)
        deadline = time.time() + seconds
        buf = bytearray()
        while time.time() < deadline:
            chunk = s.read(4096)
            if chunk:
                buf += chunk
    finally:
        s.close()
    with open(out, "wb") as f:
        f.write(bytes(buf))
    print(bytes(buf).decode("utf-8", "replace"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
