#!/usr/bin/env python3
"""把 collect.sh 的 monitor 抓帧（radiotap 封装的 tcpdump 文字摘要）整理成一行一帧。

用法：python3 tools/ap-side/frames.py <collect 输出> --epoch-offset <秒> [--board MAC] [--ap MAC] [--gw MAC] [--ws MAC]
      [--title "…"] > 证据文件
只读 "=== frames on …" 到下一个 "=== " 之间、以路由器时钟 epoch 秒开头的行。

tcpdump（radiotap）的行有两种：
  收到的帧：<epoch> <tsft>us tsft [速率 Mb/s] [频率 MHz 模式] [信号 dBm signal] [bit 22] <正文>
  AP 自己发的帧：<epoch> [速率 Mb/s] [bit 15] <正文>      ——没有信号强度
正文以 BSSID:/DA:/SA: 的地址开头（顺序不定），后面是帧的描述。
方向：AP 自己发的帧是「AP发」；其余是空中收到的，SA 是板子就是「板→…」，DA 是板子就是「…→板」。

--epoch-offset：本机时钟减路由器时钟（秒），两边各取 `date +%s` 相减。2026-11-26 量得 3 333 862
（CST = 路由器时间 + 38 天 14 小时 4 分 22 秒）；路由器没有 NTP 时每个会话重新量。
入库前：邻居的 SSID / BSSID 还要换成标签（与板侧日志同一套规则），这里不做。
"""
import argparse
import datetime
import re
import sys

BC = "ff:ff:ff:ff:ff:ff"


def main():
    ap = argparse.ArgumentParser(description="one line per 802.11 frame from collect.sh")
    ap.add_argument("path")
    ap.add_argument("--epoch-offset", type=int, required=True, help="本机时钟减路由器时钟，秒")
    ap.add_argument("--board", default="1c:29:04:d1:99:28")
    ap.add_argument("--ap", default="44:f7:70:16:fa:ba", help="AP 的 BSSID")
    ap.add_argument("--gw", default="44:f7:70:16:fa:b8", help="AP 作为网关（桥）的 MAC")
    ap.add_argument("--ws", default="c8:53:09:d0:6d:85", help="工作站的 MAC（第二台主机）")
    ap.add_argument("--title", default="")
    a = ap.parse_args()

    def role(mac):
        return {a.board: "板", a.ap: "AP", a.gw: "网关", a.ws: "工作站", BC: "广播"}.get(mac, "邻居")

    def split_line(ln):
        m = re.match(r"(\d+\.\d+) (.*)$", ln)
        if not m:
            return None
        toks = m.group(2).split(" ")
        rate = sig = None
        tx = False
        if len(toks) > 1 and toks[0].endswith("us") and toks[1] == "tsft":
            toks = toks[2:]
        if len(toks) > 1 and toks[1] == "Mb/s":
            rate = toks[0]
            toks = toks[2:]
        if len(toks) > 2 and toks[1] == "MHz":
            toks = toks[3:]  # 频率、MHz、模式（11b / 11g …）
        if len(toks) > 1 and toks[1] == "signal":
            sig = toks[0].replace("dBm", "")
            toks = toks[2:]
        if len(toks) >= 2 and toks[0] == "[bit":
            tx = toks[1] == "15]"
            toks = toks[2:]
        return m.group(1), rate, sig, tx, " ".join(toks)

    raw, on = [], False
    for ln in open(a.path, encoding="utf-8", errors="replace"):
        ln = ln.rstrip("\n")
        if ln.startswith("=== "):
            on = ln.startswith("=== frames")
            continue
        if on and re.match(r"\d+\.\d+ ", ln):
            raw.append(ln)

    out = []
    if a.title:
        out.append(a.title)
    out.append("== 帧：时间  方向  速率 信号  描述 ==")
    n = 0
    for ln in raw:
        p = split_line(ln)
        if not p:
            continue
        epoch, rate, sig, tx, body = p
        t = datetime.datetime.fromtimestamp(float(epoch) + a.epoch_offset).strftime("%H:%M:%S.%f")[:-3]
        addrs = {}
        for k, v in re.findall(r"(BSSID|DA|SA):([0-9a-f:]{17})", body):
            addrs.setdefault(k, v)
        desc = re.sub(r"(BSSID|DA|SA):[0-9a-f:]{17} ?", "", body)
        desc = desc.replace("CF +QoS ", "QoS ")
        desc = re.sub(r"\[[0-9.* ]+Mbit\]", "[速率表]", desc)
        desc = re.sub(r"Data IV:[0-9a-f]+ Pad \d+ KeyID \d+", "加密数据", desc)
        desc = desc.replace("LLC, dsap SNAP (0xaa) Individual, ssap SNAP (0xaa) Command, ctrl 0x03: oui Ethernet (0x000000), ", "")
        desc = desc.replace("[|802.11]", "(截断)")
        desc = re.sub(r"\s+", " ", desc).strip()
        if tx:
            d = "AP发→" + role(addrs.get("DA"))
        elif addrs.get("SA") == a.board:
            d = "板→" + role(addrs.get("DA") or addrs.get("BSSID"))
        elif addrs.get("DA") == a.board:
            d = role(addrs.get("SA") or addrs.get("BSSID")) + "→板"
        else:
            d = "?"
        radio = ((rate + "M") if rate else "   -") + " " + ((sig + "dBm") if sig else "  -  ")
        out.append("%s  %-9s %s  %s" % (t, d, radio, desc))
        n += 1
    out.append("")
    out.append("共 %d 帧。" % n)
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    sys.exit(main())
