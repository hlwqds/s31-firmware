#!/usr/bin/env python3
"""解码合并镜像广播实验的落盘记录（`bt-blobs/src/probe.zig` 的 `markerWrite`）。

记录在 flash `0x18E000` 起的一个扇区里，每条 32 字节（小端 8 个 32 位字）：
`[0] = 0x41445621 ^ 槽号`、`[1] = 种类`、`[2] = 槽号`、`[3..7] = a..e`。
擦过的扇区是全 FF：读到 FF 的槽就是没写过（或这一轮没走到那一步）。

用法：
    python3 tools/ap-side/decode-adv-marker.py <esptool read_flash 0x18E000 0x1000 读出的文件>

只读一个文件、只往标准输出打印，不碰串口。
"""
import struct
import sys

MAGIC = 0x41445621
WORDS = 8
KINDS = {
    1: "boot",
    2: "command",
    3: "sample",
    4: "final",
    5: "radios",
    6: "synth",
    7: "stall",
}


def decode(blob: bytes) -> list[tuple[str, list[int]]]:
    """按槽位顺序返回 (种类名, [a, b, c, d, e])。魔数不对的槽原样列为 `?`，不猜。"""
    out: list[tuple[str, list[int]]] = []
    for slot in range(len(blob) // (WORDS * 4)):
        words = struct.unpack_from("<8I", blob, slot * WORDS * 4)
        if words == (0xFFFFFFFF,) * WORDS:
            break
        kind = KINDS.get(words[1], "?")
        bad = (words[0] ^ slot) != MAGIC or words[2] != slot or kind == "?"
        out.append(("?" if bad else kind, list(words[3:])))
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(argv[1], "rb") as f:
        blob = f.read()
    recs = decode(blob)
    if not recs:
        print("扇区是空的（全 FF）：这一轮没有写到任何记录")
        return 1
    kinds = [k for k, _ in recs]
    print(f"records: {len(recs)}  " + "  ".join(f"{k}={kinds.count(k)}" for k in KINDS.values() if k in kinds))
    if "?" in kinds:
        print(f"!! 有 {kinds.count('?')} 条对不上魔数或槽号的记录，下面标 `?`")
    for i, (kind, v) in enumerate(recs):
        a, b, c, d, e = v
        if kind == "boot":
            print(f"[{i:3}] boot      98bc={a:08x} f800={b:08x} eventq_put={c} evt_seq={d}")
        elif kind == "command":
            what = {0x100: "about to send", 0x200: "no reply"}.get(b)
            if what is None and b & 0x1000:
                what = f"not sent (rc=-{b & 0xFFF})"
            elif what is None:
                what = f"status=0x{b:02x}"
            print(f"[{i:3}] command   opcode=0x{a:04x} {what}: 98bc={c:08x} f800={d:08x} evt_seq={e}")
        elif kind == "sample":
            lock = "LOCKED" if a & 4 else "unlocked"
            print(f"[{i:3}] sample     98bc={a:08x} {lock} f800={b:08x} gate7114={c:08x} evt_seq={d} cycles={e}")
        elif kind == "final":
            print(
                f"[{i:3}] final     98bc={a:08x} f800={b:08x} polls={c} locked_polls={d} evt_seq={e}"
            )
        elif kind == "stall":
            park = {1: "sem", 2: "mutex", 3: "eventq"}.get(c, "?")
            print(
                f"[{i:3}] stall      opcode=0x{a:04x} rounds={b} parked on {park} ctx=0x{d:08x} evt_seq={e}"
            )
        elif kind == "radios":
            print(f"[{i:3}] radios     98c0={a:08x} 98b8={b:08x} f818={c:08x} f81c={d:08x} clk_conf={e:08x}")
        elif kind == "synth":
            print(
                f"[{i:3}] synth      9880={a:08x} 9884={b:08x} 9888={c:08x} 988c={d:08x} 98a8={e:08x}"
            )
        else:
            print(f"[{i:3}] ?          " + " ".join(f"{x:08x}" for x in v))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
