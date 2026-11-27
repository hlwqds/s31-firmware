#!/usr/bin/env python3
"""Summarise LE Advertising Reports of one address from a capture of the Bluetooth Linux Monitor stream.

usage: pcap-bt-adv.py <file> <addr> [--tcpdump-text] [--raw] [--slot-ms T] [--report-slot-ms T]

The capture is taken on the workstation's own Bluetooth controller (needs root) with the statically
cross-compiled tcpdump (build it with BLUEZ_INCLUDE, see tools/ap-side/README.md); bluetoothctl has to
scan with `duplicate-data on` (its `scan` submenu), otherwise the controller's duplicate filter
reports each advertiser once or twice a minute, which is useless for an advertising interval:

    sudo sh -c 'timeout 150 tcpdump -i bluetooth-monitor -n -s 256 -w /tmp/bt.pcap & \
        (printf "menu scan\nduplicate-data on\nback\nscan on\n"; sleep 144; printf "scan off\n"; sleep 1) | bluetoothctl > /dev/null; wait'

Two kinds of input:

- the pcap written with -w. This script reads the file itself; it does not need tshark.
- with --tcpdump-text: the lines tcpdump prints (the build with BLUEZ_INCLUDE carries
  tools/ap-side/tcpdump-4.99.6-bt-monitor.patch, which makes it print this link type), in the
  default time format (HH:MM:SS.microseconds). Keeping only the lines of the one address
  (`grep -i <addr>`) gives a file that holds no neighbour data and can be archived, and the
  statistics can be recomputed from it later.

We collect (time, rssi, pdu type) for every "LE Advertising Report" (0x0e) or "LE Extended
Advertising Report" (0x0d) event whose address matches, group the reports into advertising events
(reports less than 30 ms apart belong to the same event; one event sweeps channels 37/38/39) and
print the inter-event interval and the RSSI statistics - the same lines as btmon-summary.py, so the
captures can be compared directly. --raw adds the per-report lines (time, rssi, pdu type) and
the distinct payloads of that address; they contain no neighbour data and can be archived. Time is
in seconds since the first record (pcap) or the first timestamped line (text).

--slot-ms T checks each inter-event gap against one advertising event of T ms plus 0-10 ms
advDelay (Core Vol 6 Part B §4.4.2): a gap fits if some k >= 1 has k*T <= gap <= k*(T+10). Reports
are sparse, so the mean says little; what holds is that every gap is a multiple of the event length.
--report-slot-ms T does the same check on the gaps between consecutive reports, without the 30 ms
grouping: for an interval shorter than 30 ms (the minimum, 20 ms) the grouping merges neighbouring
advertising events, so the event gaps mean nothing there.

pcap layout (checked record by record against tshark 4.6.10 on 2026-11-27): link type 254
(BLUETOOTH_LINUX_MONITOR); every record is adapter id (2 bytes, big-endian), opcode (2 bytes,
big-endian; 3 = HCI event packet) and then the HCI event packet without its 0x04 type byte. Other
opcodes (commands, mgmt control events, system notes) are ignored here.

The raw capture, pcap or text, contains every neighbour's advertisement: never archive it; keep the
summary or the lines of the one address.
"""
import re
import struct
import statistics
import sys

LINKTYPE_BLUETOOTH_LINUX_MONITOR = 254
HCI_MON_EVENT_PKT = 3
# LE Extended Advertising Report, Event Type (Core Vol 4 Part E §7.7.65.17): bit 0 connectable, 1 scannable,
# 2 directed, 3 scan response, 4 legacy. Legacy PDUs are named from those flags the way btmon does: controllers
# leave the Legacy PDU Type bits (10-12) at 0 (the 50 other advertisers of 2026-11-27 all did), so they are no use.
ADDR_TYPE = {0: "Public", 1: "Random", 2: "Public identity", 3: "Random identity"}


def read_records(path):
    """Yield (seconds since the first record, payload bytes) for every record."""
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 24:
        raise ValueError("shorter than a pcap file header")
    magic = data[:4]
    endian = {b"\xd4\xc3\xb2\xa1": "<", b"\x4d\x3c\xb2\xa1": "<",
              b"\xa1\xb2\xc3\xd4": ">", b"\xa1\xb2\x3c\x4d": ">"}.get(magic)
    if endian is None:
        raise ValueError("not a pcap file (magic %s); pcapng is not handled" % magic.hex())
    linktype, = struct.unpack(endian + "I", data[20:24])
    if linktype != LINKTYPE_BLUETOOTH_LINUX_MONITOR:
        raise ValueError("link type %d, not BLUETOOTH_LINUX_MONITOR (%d)" % (linktype, LINKTYPE_BLUETOOTH_LINUX_MONITOR))
    tick = 1e-9 if magic in (b"\xa1\xb2\x3c\x4d", b"\x4d\x3c\xb2\xa1") else 1e-6
    off, t0 = 24, None
    while off + 16 <= len(data):
        sec, frac, incl, _ = struct.unpack(endian + "IIII", data[off:off + 16])
        rec = data[off + 16:off + 16 + incl]
        off += 16 + incl
        if len(rec) != incl:
            break  # truncated last record
        t = sec + frac * tick
        if t0 is None:
            t0 = t
        yield t - t0, rec


def adv_reports(rec):
    """Yield (address bytes, rssi, pdu type name, address type name, payload) of one HCI event record."""
    if len(rec) < 6 or rec[2:4] != struct.pack(">H", HCI_MON_EVENT_PKT) or rec[4] != 0x3e:
        return
    params, sub = rec[6:], rec[5]
    if len(params) < sub or sub < 1:
        return
    params, sub = params[:sub], params[0]
    if sub == 0x0d and len(params) >= 2:  # LE Extended Advertising Report
        i, n = 2, params[1]
        for _ in range(n):
            if i + 24 > len(params):
                return
            etype, = struct.unpack("<H", params[i:i + 2])
            atype = params[i + 2]
            addr = params[i + 3:i + 9]
            rssi = struct.unpack("<b", params[i + 13:i + 14])[0]
            dlen = params[i + 23]
            payload = params[i + 24:i + 24 + dlen]
            if etype & 0x10:
                flags = etype & 0x0f
                if flags & 0x04:
                    pdu = "ADV_DIRECT_IND"
                elif flags & 0x08:
                    pdu = "SCAN_RSP"
                elif flags & 0x01:
                    pdu = "ADV_IND"
                elif flags & 0x02:
                    pdu = "ADV_SCAN_IND"
                else:
                    pdu = "ADV_NONCONN_IND"
            else:
                pdu = "AUX_SCAN_RSP" if etype & 0x08 else "AUX_ADV"
            yield addr, rssi, pdu, ADDR_TYPE.get(atype, "0x%02x" % atype), payload
            i += 24 + dlen
    elif sub == 0x0e and len(params) >= 2:  # LE Advertising Report: one byte per field, RSSI after the data
        i, n = 2, params[1]
        for _ in range(n):
            if i + 9 >= len(params):  # event type, address type, address, data length, data, rssi
                return
            etype, atype, addr, dlen = params[i], params[i + 1], params[i + 2:i + 8], params[i + 8]
            if i + 10 + dlen > len(params):
                return
            payload = params[i + 9:i + 9 + dlen]
            rssi = struct.unpack("<b", params[i + 9 + dlen:i + 10 + dlen])[0]
            names = {0: "ADV_IND", 1: "ADV_DIRECT_IND", 2: "ADV_SCAN_IND", 3: "ADV_NONCONN_IND", 4: "SCAN_RSP"}
            yield addr, rssi, names.get(etype, "0x%02x" % etype), ADDR_TYPE.get(atype, "0x%02x" % atype), payload
            i += 10 + dlen


# The lines tcpdump prints for this link type: "HH:MM:SS.uuuuuu adapter 0, HCI Event: LE Extended Advertising
# Report (0x3e/0x0d): 1 report, ADV_NONCONN_IND Public 02:00:00:00:bb:01, adv data 8 B, Flags 0x06, rssi -51 dBm".
TEXT_STAMP = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d{6}) ")
TEXT_HEAD = re.compile(r"LE ((?:Extended )?)Advertising Report \(0x3e/0x0[02d]\): (\d+) reports?, ")
TEXT_REPORT = re.compile(r"([A-Z_]+) (\S+ \S*|Public|Random) ([0-9a-f]{2}(?::[0-9a-f]{2}){5}), ")


def read_tcpdump_text(path):
    """Return ([(seconds, address bytes, rssi, pdu type, address type, advertising data text)], span in seconds)."""
    rows, t0, t_last = [], None, 0.0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            stamp = TEXT_STAMP.match(line)
            if not stamp:
                continue
            h, m, s, us = (int(x) for x in stamp.groups())
            t = h * 3600 + m * 60 + s + us / 1e6
            if t0 is None:
                t0 = t
            t_last = t
            head = TEXT_HEAD.search(line)
            if not head:
                continue
            pos, n = head.end(), int(head.group(2))
            for _ in range(n):
                start = TEXT_REPORT.match(line, pos)
                if not start:
                    break
                end = line.find(", rssi ", start.end())
                if end < 0:
                    break
                rssi = line[end + 7:].split(", ")[0]
                rows.append((t - t0, bytes.fromhex(start.group(3).replace(":", ""))[::-1],
                             None if rssi == "n/a" else int(rssi[:-4]), start.group(1), start.group(2),
                             line[start.end():end].strip(", ")))
                pos = end + 7 + len(rssi) + 2
    if t0 is None:
        raise ValueError("no tcpdump line with a timestamp (default time format HH:MM:SS.uuuuuu expected)")
    return rows, t_last - t0


def stats(v, digits=1):
    if not v:
        return "n/a"
    f = (lambda x: ("%%.%df" % digits) % x)
    text = "n=%d min=%s median=%s mean=%s max=%s" % (len(v), f(min(v)), f(statistics.median(v)), f(statistics.mean(v)), f(max(v)))
    if len(v) >= 4:
        q = statistics.quantiles(v, n=20)
        text += " p5=%s p95=%s" % (f(q[0]), f(q[-1]))
    return text


def slot_check(gaps, slot_ms):
    """For each gap the smallest k with k*T <= gap <= k*(T+10); None when there is none."""
    ks = []
    for g in gaps:
        ks.append(next((k for k in range(1, int(g / slot_ms) + 1) if k * slot_ms <= g <= k * (slot_ms + 10)), None))
    fitted = [k for k in ks if k is not None]
    print("against one advertising event of %d ms + 0-10 ms advDelay: %d of %d gaps are a whole number of events"
          % (slot_ms, len(fitted), len(gaps)))
    if fitted:
        per = [g / k for g, k in zip(gaps, ks) if k]
        hist = {}
        for k in fitted:
            hist[k] = hist.get(k, 0) + 1
        print("  events per gap (k: gaps): %s; per-event length from the fitted gaps ms: %s"
              % (", ".join("%d: %d" % (k, n) for k, n in sorted(hist.items())), stats(per)))
    if len(fitted) < len(gaps):
        print("  gaps that do not fit ms: %s" % " ".join("%.1f" % g for g, k in zip(gaps, ks) if k is None))


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)  # the usage line
        return 2
    path, addr = argv[1], argv[2].lower()
    raw = "--raw" in argv[3:]
    text = "--tcpdump-text" in argv[3:]
    want = bytes.fromhex(addr.replace(":", ""))[::-1]  # HCI reports store the address least-significant byte first
    reports, count, span, kind = [], 0, 0.0, "pcap %s" % path
    try:
        if text:
            rows, span = read_tcpdump_text(path)
            reports = [(t, rssi, pdu, atype, data) for t, a, rssi, pdu, atype, data in rows if a == want]
            count = sum(1 for _ in rows)
            kind = "tcpdump text %s" % path
        else:
            records = list(read_records(path))
            span = records[-1][0] if records else 0.0
            count = len(records)
            for t, rec in records:
                for a, rssi, pdu, atype, payload in adv_reports(rec):
                    if a == want:
                        reports.append((t, rssi, pdu, atype, payload.hex()))
    except (ValueError, OSError) as e:
        print("%s: %s" % (path, e))
        return 2
    if not reports:
        print("no LE Advertising Report for %s in %s (%d records)" % (addr, kind, count))
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
    payloads = {}
    for r in reports:
        key = (r[2], r[3], r[4])
        payloads[key] = payloads.get(key, 0) + 1
    gaps = [(events[i + 1][0][0] - events[i][0][0]) * 1000 for i in range(len(events) - 1)]
    rssis = [r[1] for r in reports if r[1] is not None]
    print("%s: %d records, %.1f s; address %s: %d reports in %d advertising events, %.1f s (%.3f-%.3f s)"
          % (kind, count, span, addr, len(reports), len(events),
             reports[-1][0] - reports[0][0], reports[0][0], reports[-1][0]))
    print("pdu types: %s" % sorted({r[2] for r in reports}))
    print("address types: %s" % sorted({r[3] for r in reports}))
    per_event = [len(e) for e in events]
    print("reports per advertising event: median %d, min %d, max %d" % (statistics.median(per_event), min(per_event), max(per_event)))
    print("inter-event interval ms: %s" % stats(gaps))
    intra = [(b[0] - a[0]) * 1000 for e in events for a, b in zip(e, e[1:])]
    if intra:
        print("intra-event spacing ms: %s" % stats(intra))
    print("RSSI dBm: %s" % stats(rssis, 0))
    rest = argv[3:]
    while "--slot-ms" in rest:
        slot = rest.index("--slot-ms")
        if slot + 1 < len(rest):
            slot_check(gaps, float(rest[slot + 1]))
        rest = rest[slot + 2:]
    report_gaps = [(b[0] - a[0]) * 1000 for a, b in zip(reports, reports[1:])]
    while "--report-slot-ms" in rest:
        slot = rest.index("--report-slot-ms")
        if slot + 1 < len(rest):
            print("consecutive reports, no grouping: %d gaps" % len(report_gaps))
            slot_check(report_gaps, float(rest[slot + 1]))
        rest = rest[slot + 2:]
    if raw:
        print("-- per report: seconds since the first record, rssi dBm, pdu type")
        for r in reports:
            print("%.6f %s %s" % (r[0], "n/a" if r[1] is None else r[1], r[2]))
        print("-- distinct payloads of %s (pdu type, address type, advertising data, reports)" % addr)
        for (pdu, atype, data), n in sorted(payloads.items()):
            print("%s %s %s %d" % (pdu, atype, data, n))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
