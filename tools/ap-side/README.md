# AP 侧取证：从 OpenWrt AP 那一头看板子的 Wi-Fi

真实链路的证据原先都来自板子自己的日志。这里是从 AP 那一头取的旁证：AP 记的事件、AP 对这条链路的统计、AP 接口上的帧、
空口上的 802.11 帧。测试用的 AP 是刷了 OpenWrt 25.12.6 的小米 AX3000T（2.4 GHz 信道 1，接口 `phy0-ap0`，网关
192.168.31.1）。它没有外网，`apk` 装不了 tcpdump，所以自己交叉编译一个静态的。

| 文件 | 在哪跑 | 做什么 |
| --- | --- | --- |
| `build-tcpdump.sh` | 工作站 | 用 `zig cc -target aarch64-linux-musl` 编 libpcap 1.10.5 与 tcpdump 4.99.6，静态链接，约 1.4 MB |
| `collect.sh` | 路由器 | 跟随系统日志、每秒读站点统计、tcpdump 抓帧的文字摘要；`MON` 模式临时建 monitor 接口抓 802.11 帧 |
| `frames.py` | 工作站 | 把 monitor 抓到的帧整理成一行一帧，时间换算成本机时间 |
| `redact.py` | 工作站 | 入库前的脱敏：邻居的 SSID / BSSID 换成标签（板侧日志与帧清单都能用），自检残留 |
| `decode-adv-marker.py` | 工作站 | 解码合并镜像广播实验的落盘记录（flash `0x18E000` 起一个扇区，`bt-blobs/src/probe.zig` 的 `markerWrite` 写的）：每条 32 字节，按槽位顺序打印；全 FF 的扇区报「空的」。记录只写到广播使能的"正要发"为止——之后板子不再出声（生产仓 `coex-verification.md` §17） |

## 用法

```sh
# 1) 编（约 20 秒；需要 zig、flex 与 bison——PATH 里没有就用 nix 取）
sh tools/ap-side/build-tcpdump.sh                      # -> /tmp/ap-side/out/tcpdump

# 2) 传到路由器的内存盘上，不是装包；重启即消失
ssh root@192.168.31.1 'cat > /tmp/ap-tcpdump && chmod 700 /tmp/ap-tcpdump' < /tmp/ap-side/out/tcpdump
ssh root@192.168.31.1 /tmp/ap-tcpdump --version        # 4.99.6, libpcap 1.10.5

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
