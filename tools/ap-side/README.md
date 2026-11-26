# AP 侧取证：从 OpenWrt AP 那一头看板子的 Wi-Fi

真实链路的证据原先都来自板子自己的日志。这里是从 AP 那一头取的旁证：AP 记的事件、AP 对这条链路的统计、AP 接口上的帧、
空口上的 802.11 帧。测试用的 AP 是刷了 OpenWrt 25.12.6 的小米 AX3000T（2.4 GHz 信道 1，接口 `phy0-ap0`，网关
192.168.31.1）。它没有外网，`apk` 装不了 tcpdump，所以自己交叉编译一个静态的，再放到路由器的 `/usr/bin/tcpdump`。

| 文件 | 在哪跑 | 做什么 |
| --- | --- | --- |
| `build-tcpdump.sh` | 工作站 | 用 `zig cc -target aarch64-linux-musl` 编 libpcap 1.10.5 与 tcpdump 4.99.6，静态链接，约 1.4 MB |
| `collect.sh` | 路由器 | 跟随系统日志、每秒读站点统计、tcpdump 抓帧的文字摘要；`MON` 模式临时建 monitor 接口抓 802.11 帧 |
| `frames.py` | 工作站 | 把 monitor 抓到的帧整理成一行一帧，时间换算成本机时间 |
| `redact.py` | 工作站 | 入库前的脱敏：邻居的 SSID / BSSID 换成标签（板侧日志与帧清单都能用），自检残留 |
| `decode-adv-marker.py` | 工作站 | 解码合并镜像广播实验的落盘记录（flash `0x18E000` 起一个扇区，`bt-blobs/src/probe.zig` 的 `markerWrite` 写的）：每条 32 字节，按槽位顺序打印；全 FF 的扇区报「空的」。记录只写到广播使能的"正要发"为止——当时的理由是"之后板子不再出声"，那其实是 `bt-blobs` 的中断风暴，2026-11-27 晚已修（生产仓 `coex-verification.md` §17.5）；记录本身仍然冻结在那里，没有改回 |
| `btmon-summary.py` | 工作站 | 蓝牙一侧：从 `btmon` 的输出里汇总板子地址的 LE 广播上报，按广播事件分组，给出事件间隔与 RSSI 的统计；`--raw` 逐条列出（见下文「蓝牙一侧」） |

## 用法

```sh
# 1) 编（约 20 秒；需要 zig、flex 与 bison——PATH 里没有就用 nix 取）
sh tools/ap-side/build-tcpdump.sh                      # -> /tmp/ap-side/out/tcpdump
#
#    工作站自己没有 tcpdump 时，同一个脚本换个 TARGET 再编一份给自己（只给当前用户装，rm 即卸载；~/.local/bin 要在 PATH 里）：
env -u LD_LIBRARY_PATH TARGET=x86_64-linux-musl sh tools/ap-side/build-tcpdump.sh   # -> /tmp/ap-side/out/x86_64-linux-musl/tcpdump
install -m 755 /tmp/ap-side/out/x86_64-linux-musl/tcpdump ~/.local/bin/tcpdump
#    在本机网口上抓帧要 root（CAP_NET_RAW）；列接口（-D）与 --version 不需要

# 2) 传到路由器上，装成标准名字 tcpdump（持久的：约占 1.4 MB 的 overlay 空间；卸载就是 rm 这一个文件）。
#    只放到内存盘 /tmp 的话路由器一重启就没了，而且在路由器上敲 tcpdump 会是 not found。
ssh root@192.168.31.1 'cat > /tmp/tcpdump.new && chmod 755 /tmp/tcpdump.new && mv /tmp/tcpdump.new /usr/bin/tcpdump' \
    < /tmp/ap-side/out/tcpdump
ssh root@192.168.31.1 tcpdump --version                 # 4.99.6, libpcap 1.10.5

# 3) 上板那一轮开始时，在路由器上起采集（第二个参数：接口名 / any / MON）；约 150 秒后输出到标准输出
ssh root@192.168.31.1 sh -s 150 MON < tools/ap-side/collect.sh > ap-<轮次>.txt

# 4) 整理帧。--epoch-offset 是「本机时钟减路由器时钟」的秒数：两边各取 date +%s 相减
python3 tools/ap-side/frames.py ap-<轮次>.txt --epoch-offset 3333862
python3 tools/ap-side/redact.py --map <label-map.json> --cred <凭据文件> --kind frames --date <日期> <帧清单> <脱敏后的帧清单>

# 5) 广播实验（ADV=1）之后读板子上的落盘记录（会让板子复位）：命令发到哪、回没回看它。
#    主循环在这之后活没活，看 AP 这一侧——同一轮起 MON 采集：板子还有没有帧、有没有第二次关联
python3 -m esptool --chip esp32s31 -p /dev/ttyUSB0 read_flash 0x18E000 0x1000 adv-marker.bin
python3 tools/ap-side/decode-adv-marker.py adv-marker.bin
```

`collect.sh` 找 tcpdump 的顺序：`$TCPDUMP` → PATH 里的 `tcpdump` → `/tmp/ap-tcpdump` → `/tmp/r5c-tcpdump`（后两个在内存盘上）；
哪一份被用了，采集输出里有一行 `tcpdump: <路径> (<版本>)`。

2026-11-27 的实际状态：测试用的那台路由器上已经装在 `/usr/bin/tcpdump`，sha256 `4412618629482af45397b3886c931f402266bcf2aad29e33dab925db5a9e566a`，
与工作站的构建产物一致；内存盘上另有一份 `/tmp/r5c-tcpdump`。工作站（x86_64）上装在 `~/.local/bin/tcpdump`
（sha256 `d2cd67c68e806cc35ad69b1a3ffb0171a720e2da35ad75571f61c0a6d079f916`），用它在本机网口上抓到过一帧。

登录需要路由器的 root 密码（问用户）。工作站要在这台 AP 的 LAN 里（网线接 LAN 口；板子的以太网线这时是拔的），
默认路由留在原来的网卡上，别让登 AP 这条线抢默认路由。

## 三种抓法各能看到什么

| 抓包对象 | 看得到 | 看不到 |
| --- | --- | --- |
| `phy0-ap0`（AP 接口） | 数据面的帧，已由驱动转成以太网格式：DHCP、ARP、ICMP、块确认协商之后的加密数据帧的以太网头；微秒级时间戳 | 管理帧（认证、关联、去认证：走 nl80211，不经过网卡的抓包点）；**EAPOL**（本机内核 6.12 + mt76 上四个方向都试过，抓不到） |
| `any` | 每一帧经过哪些接口（`phy0-ap0` → `br-lan` → `lan4` / `eth0` / `phy1-ap0`）；量很大 | 同上 |
| `MON`（临时 monitor 接口） | 空口上的 802.11 帧：探测、认证、关联、EAPOL 四条、加密数据帧的首部、解关联、去认证；带微秒时间戳、速率、信号。AP 自己发的帧 tcpdump 标 `[bit 15]`，没有信号强度 | 载荷（本来就是密文；EAPOL 的密钥数据不在文字摘要里） |

`MON` 模式只抓地址里有板子 MAC 的帧，邻居的流量不抓；monitor 接口与 AP 在同一个射频、同一个信道上，建得起来也删得干净
（mt76 实测）。它是在路由器上的一处**运行时**改动：`collect.sh` 在退出、出错、被中断时都删掉它，不写任何持久配置。

## 蓝牙一侧：板子的 BLE 广播（工作站上抓）

板子的 BLE 广播不从 AP 那一头看，用工作站自带的蓝牙控制器：hci0，bluez 5.86 的 `btmon` 记 HCI 事件，要 root。

```bash
sudo -k -S -p '' sh -c 'timeout 60 btmon > /tmp/btmon.txt 2>&1 & (printf "menu scan\nduplicate-data on\nback\nscan on\n"; sleep 55) | bluetoothctl > /dev/null; wait' < <(放 sudo 密码的文件)
python3 tools/ap-side/btmon-summary.py /tmp/btmon.txt 02:00:00:00:BB:01 --raw
```

- `duplicate-data on` 是关键。默认的 `bluetoothctl scan on` 让内核下发 LE Set Extended Scan Enable 时开着控制器的重复
  过滤，同一个广播者 56 秒只上报一两次；进了 `scan` 子菜单把它打开之后，内核下发的是 Filter duplicates = Disabled
  （2026-11-27 在 btmon 里对过），每一次被扫描窗口碰到的广播事件都上报。命令行上没有这个开关（`bluetoothctl --help`
  里没有 `--duplicate-data`），只有子菜单里的这条命令。
- 板子那一轮的广播窗口：开跑后约 72–120 秒（构建 25 秒、烧录 15 秒、第一遍 Wi-Fi 链路约 40 秒之后起广播约 45 秒）。
  板子的广播地址是 `02:00:00:00:BB:01`——合并镜像没有接读 eFuse MAC 的钩子，这是回退值。
- 上报很稀（2026-11-27 一轮 56 秒里板子只有 20 次，原因没有查），所以间隔要用「每一段都是广播间隔加 advDelay 的整数倍」
  来判，不能只看相邻两条的平均。`--raw` 的逐条输出只有板子的时间、RSSI、PDU 类型，可以直接入库。
- 原始的 btmon 输出里有每一个邻居的广告（地址与广播数据原文），不入库；要 PDU 原文就只摘板子地址的那几块。
- 走不通的三条，别再试：自编的静态 tcpdump 认不得 bluetooth-monitor 接口（libpcap 编译时没有 bluez 头文件）；bluetoothd
  在管着控制器时用 `hcitool` 直接发 LE 扫描命令回 0x12；HCI 用户通道（要先 `bluetoothctl power off`）打开之后，这台
  Intel 控制器对 LE Set Scan Param / Enable 回 0x12、对 Intel Read Version 回 0x01——没有经过 btusb / btintel 的厂商初始化。
- 证据：`logs/coex-merged-wifi-link-ble-adv14-btmon.txt`（两条广播上报的原文：PDU 类型、地址类型、广播数据、RSSI）、
  `logs/coex-merged-wifi-link-ble-adv15-advinterval.txt`（间隔：19 段都是 100 ms 加 advDelay 的整数倍）。

## 入库前的规矩

- 只入库文字摘要，不入库 pcap；tcpdump 不带 `-v` / `-x`，EAPOL 帧只有 `EAPOL key (3) v2, len 95` 这样的首部摘要。
- monitor 抓到的帧里有邻居 AP 对板子探测请求的应答（邻居的 SSID 与 BSSID）：入库前用 `redact.py` 换成标签，与板侧日志
  同一套编号（标签表不入库，编号规则在 `redact.py` 的文件头）；用户自己的 AP、板子、工作站的地址原样保留。
  板侧日志同理（`--kind board`，扫描结果里有邻居的 SSID 与 BSSID）。
- 路由器的登录记录（dropbear 的行）不入库。
- 路由器的系统日志是个约 1300 行的环形缓冲，新的挤掉旧的，要引用就当场取回。

## 已知现象

- 管理帧与 EAPOL 在 AP 接口与 `any` 上都抓不到（内核 6.12.112 + mt76 实测），要它们只能用 `MON`。
- 在 AP 接口上，板子发来的**广播**帧每个出现三次（`phy0-ap0` 上一份以太网格式、一份驱动层的原始帧，再加桥的洪泛），
  同一帧的三份出现在 0、40、79 微秒处，不是板子在重传（板子下一次重发隔 14.8 ms）；板子发的单播帧只出现一次。原因没有查。
- `MON` 模式下 AP 自己发出的帧，时间戳不保证是第一次发出的时刻：对照 E 的第三次里一个回显应答，板子量到的往返最大
  18.7 ms，清单里的帧却比请求晚 384 ms。AP → 板子这一侧的重传节奏以站点统计（`tx retries` / `tx failed`）为准。
- `MON` 模式的清单里没有控制帧（ACK、块确认、RTS / CTS）；原因没有查。
- `MON` 模式会把同一帧交付两次甚至三次（时间戳与内容完全相同）：2026-11-27 的五轮 373 行里有 5 行，数帧数时要扣掉。
- `MON` 模式的清单里单独成行的 `QoS` 是没有载荷的 QoS 帧（QoS Null）；作用没有查。
