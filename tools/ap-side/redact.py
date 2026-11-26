#!/usr/bin/env python3
"""入库前的脱敏：把日志或帧清单里邻居网络的 SSID / BSSID 换成标签，用户自己的 AP 原样保留，并自检。

用法：
  redact.py --map label-map.json --cred 凭据文件 --kind board|frames --date YYYY-MM-DD 原始文件 输出文件

标签表 label-map.json **不入库**（里面有真实的 SSID 与 BSSID）。JSON，键是 "<BSSID>|<SSID>"，值是
["<ap-NN>"（用户自己的 AP 是原 BSSID）, 标签]。编号规则与 `logs/wifi-link-scan-boot.log` 那一套一致：

  - BSSID 换成 ap-NN，编号来自标签表；日志里新出现的 BSSID 接着往后编（同一次运行里稳定）。
    要让编号跨文件稳定，就把新出现的 BSSID 补进标签表。
  - SSID 换成 ssid-NN，取同名 BSSID 里最小的编号；同名 mesh 的几个 BSSID 共用一个标签。
  - 用户自己的 AP、板子、工作站的地址原样保留。

`--kind board` 用于板侧串口日志（会从 `ap[i] bssid=… ssid="…"` 行里认出新的 BSSID，并在文件头加一行说明）；
`--kind frames` 用于 monitor 接口抓到的帧清单（SSID 出现在 `Probe Response (名字)`、`Assoc Request (名字)` 里）。
退出码：自检发现残留（邻居的 SSID / BSSID、AP 口令还在输出里）时为 1，残留计数打到标准输出。
"""
import argparse
import json
import re
import sys

AP_LINE = re.compile(r'ap\[(\d+)\] bssid=([0-9a-f:]{17}) ssid="([^"]*)"')
FRAME_SSID = re.compile(r'(Probe Response|Assoc Request|Probe Request) \(([^)]*)\)')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--map', required=True, help='label-map.json（不入库）')
    ap.add_argument('--cred', required=True, help='凭据文件：第 1 行用户自己的 SSID，第 2 行口令')
    ap.add_argument('--kind', choices=['board', 'frames'], required=True)
    ap.add_argument('--date', required=True, help='写进文件头的日期')
    ap.add_argument('--save-map', help='把日志里新出现的 BSSID 连同分到的编号写回这份标签表（JSON，不入库），让编号跨文件稳定')
    ap.add_argument('raw')
    ap.add_argument('out')
    a = ap.parse_args()

    # 按字节透明地解码（surrogateescape）：标签表里的 SSID 是 UTF-8 文本，只有原样还原成同样的字符串才能匹配得上，
    # 中文一类非 ASCII 的 SSID 才不会被漏替换、也不会逃过自检。
    data = open(a.raw, 'rb').read().decode('utf-8', 'surrogateescape')
    cred = open(a.cred).read().split('\n')
    own_ssid, password = cred[0].strip(), (cred[1].strip() if len(cred) > 1 else '')

    bssid_num, ssid_of = {}, {}
    for key, val in json.load(open(a.map)).items():
        bssid, _, ssid = key.partition('|')
        m = re.search(r'ap-(\d+)', val[0])
        if m:
            bssid_num[bssid] = int(m.group(1))
            ssid_of[bssid] = ssid
    next_num = max(bssid_num.values(), default=0) + 1
    if a.kind == 'board':
        for _, bssid, ssid in AP_LINE.findall(data):
            if bssid not in bssid_num:
                bssid_num[bssid] = next_num
                next_num += 1
            ssid_of[bssid] = ssid
    else:
        # 帧清单里的 BSSID 已经被 frames.py 换成方向列了，这里只换 SSID 与可能残留的 BSSID；标签取标签表里已有的编号。
        nums = {}
        for bssid, ssid in ssid_of.items():
            if ssid != own_ssid:
                nums[ssid] = min(nums.get(ssid, 10 ** 9), bssid_num[bssid])

        def sub_ssid(m):
            name = m.group(2)
            return '%s (%s)' % (m.group(1), 'ssid-%02d' % nums[name] if name in nums else name)

        out = re.sub(FRAME_SSID.pattern, sub_ssid, data)
        for bssid, num in sorted(bssid_num.items(), key=lambda kv: -len(kv[0])):
            if ssid_of[bssid] != own_ssid:
                out = re.sub(re.escape(bssid), 'ap-%02d' % num, out, flags=re.I)
        return finish(a, out, own_ssid, password, ssid_of)

    ssid_num = {}
    for bssid, ssid in ssid_of.items():
        if ssid == own_ssid:
            continue
        ssid_num[ssid] = min(ssid_num.get(ssid, 10 ** 9), bssid_num[bssid])

    out = data
    for bssid, num in sorted(bssid_num.items()):
        if ssid_of[bssid] != own_ssid:
            out = out.replace(bssid, 'ap-%02d' % num)
    for ssid in sorted((s for s in ssid_num if s), key=len, reverse=True):
        out = out.replace(ssid, 'ssid-%02d' % ssid_num[ssid])
    header = (
        '[REDACTED %s] 本文件是板侧原始串口日志的脱敏副本：除用户自己的 AP（%s）外，邻居网络的 SSID 与 BSSID '
        '都换了标签——BSSID 换成 ap-NN（与 wifi-link-scan-boot.log 同一套编号，日志里新出现的 BSSID 接着往后编），'
        'SSID 换成 ssid-NN（每个 SSID 名一个，同名 mesh 的几个 BSSID 共用）；信道、RSSI、authmode、握手内容、'
        '栈的高水位、时序与计数都是原值。\n' % (a.date, own_ssid)
    )
    if a.save_map:
        save_map(a.save_map, bssid_num, ssid_of, own_ssid)
    return finish(a, header + out, own_ssid, password, ssid_of)

def save_map(path, bssid_num, ssid_of, own_ssid):
    table = {}
    for bssid, ssid in ssid_of.items():
        if ssid == own_ssid:
            table['%s|%s' % (bssid, ssid)] = [bssid, ssid]
        elif bssid in bssid_num:
            table['%s|%s' % (bssid, ssid)] = ['<ap-%02d>' % bssid_num[bssid]] * 2
    with open(path, 'w') as f:
        json.dump(table, f, ensure_ascii=False, indent=1)


def finish(a, out, own_ssid, password, ssid_of) -> int:
    leftover = 0
    for bssid, ssid in ssid_of.items():
        if ssid != own_ssid and (bssid in out or (ssid and ssid in out)):
            leftover += 1
    if password and password in out:
        leftover += 100
    open(a.out, 'wb').write(out.encode('utf-8', 'surrogateescape'))
    print('labels: %d bssids; leftover=%d%s' % (
        len({b for b in ssid_of if ssid_of[b] != own_ssid}), leftover, ' (口令还在输出里)' if leftover >= 100 else ''))
    return 1 if leftover else 0


if __name__ == '__main__':
    sys.exit(main())
