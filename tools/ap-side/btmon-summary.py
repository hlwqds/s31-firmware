#!/usr/bin/env python3
"""Summarise LE Advertising Reports of one address from a `btmon` text capture (BLE side of the board).

usage: btmon-summary.py <btmon.txt> <addr> [--raw]

How the capture is taken (workstation, needs root):

    sudo -k -S -p '' sh -c 'timeout 60 btmon > /tmp/btmon.txt 2>&1 & \
        (printf "menu scan\nduplicate-data on\nback\nscan on\n"; sleep 55) | bluetoothctl > /dev/null; wait' < <(密码)

`duplicate-data on` (bluetoothctl's `scan` submenu) is what makes the kernel send LE Set Extended Scan
Enable with Filter duplicates = Disabled; the default scan enables the controller's duplicate filter and
reports each advertiser once or twice in a minute, which is useless for an advertising interval.

btmon prints one HCI packet as an indented block; the first line of a block is the packet header
(e.g. "> HCI Event: LE Meta Event (0x3e) plen 34      #4 [hci0] 1.528689") ending with the monitor
timestamp in seconds. We collect (timestamp, rssi, pdu type) for every "LE Advertising Report" or
"LE Extended Advertising Report" whose address matches, group the reports into advertising events
(reports less than 30 ms apart belong to the same event; one event sweeps channels 37/38/39) and
print the inter-event interval and the RSSI statistics. With --raw the per-report lines are printed
as well (time, rssi, pdu type) - they contain no neighbour data and can be archived.

The raw btmon capture contains every neighbour's advertisement: never archive it; keep the summary
and, if the PDU itself matters, the report blocks of the board's address only.
"""
import re
import statistics
import sys

HEAD = re.compile(r"^[<>]\s+HCI Event:.*\[hci\d+\]\s+(\d+\.\d+)\s*$")
META = re.compile(r"LE ((?:Extended )?)Advertising Report \(0x0[02d]\)")
PEER = re.compile(r"^\s*(Peer address|Address):\s*([0-9A-Fa-f:]{17})")
RSSI = re.compile(r"RSSI:\s*(-?\d+)\s*dBm")
ETYPE = re.compile(r"(?:Event type|Legacy PDU Type):\s*(?:0x[0-9a-f]+\s*\()?([^)]*)")


def stats(v, digits=1):
    if not v:
        return "n/a"
    f = (lambda x: ("%%.%df" % digits) % x)
    text = "n=%d min=%s median=%s mean=%s max=%s" % (len(v), f(min(v)), f(statistics.median(v)), f(statistics.mean(v)), f(max(v)))
    if len(v) >= 4:
        q = statistics.quantiles(v, n=20)
        text += " p5=%s p95=%s" % (f(q[0]), f(q[-1]))
    return text


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)  # the usage line
        return 2
    path, addr = argv[1], argv[2].lower()
    raw = "--raw" in argv[3:]
    reports, ts, in_meta = [], None, False
    cur_peer, cur_rssi, cur_type = None, None, None

    def flush():
        if in_meta and cur_peer == addr and cur_rssi is not None:
            reports.append((float(ts), cur_rssi, cur_type))

    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = HEAD.match(line)
            if m:
                flush()
                ts, in_meta, cur_peer, cur_rssi, cur_type = m.group(1), False, None, None, None
                continue
            if META.search(line):
                in_meta = True
                continue
            if in_meta:
                p = PEER.match(line)
                if p:
                    cur_peer = p.group(2).lower()
                    continue
                r = RSSI.search(line)
                if r:
                    cur_rssi = int(r.group(1))
                    continue
                e = ETYPE.search(line)
                if e and cur_type is None:
                    cur_type = e.group(1).strip()
    flush()
    if not reports:
        print("no LE Advertising Report for %s in %s" % (addr, path))
        return 1
    reports.sort()
    events, cur = [], [reports[0]]
    for r in reports[1:]:
        if r[0] - cur[-1][0] <= 0.030:
            cur.append(r)
        else:
            events.append(cur)
            cur = [r]
    events.append(cur)
    gaps = [(events[i + 1][0][0] - events[i][0][0]) * 1000 for i in range(len(events) - 1)]
    rssis = [r[1] for r in reports]
    print("address %s: %d reports in %d advertising events, %.1f s of capture (%.3f-%.3f s)"
          % (addr, len(reports), len(events), reports[-1][0] - reports[0][0], reports[0][0], reports[-1][0]))
    print("pdu types: %s" % sorted({str(r[2]) for r in reports}))
    per_event = [len(e) for e in events]
    print("reports per advertising event: median %d, min %d, max %d" % (statistics.median(per_event), min(per_event), max(per_event)))
    print("inter-event interval ms: %s" % stats(gaps))
    intra = [(b[0] - a[0]) * 1000 for e in events for a, b in zip(e, e[1:])]
    if intra:
        print("intra-event spacing ms: %s" % stats(intra))
    print("RSSI dBm: %s" % stats(rssis, 0))
    if raw:
        print("-- per report: seconds, rssi dBm, pdu type")
        for r in reports:
            print("%.6f %d %s" % r)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
