# wifi-idf-oracle：官方 IDF 的最小 station（对照用）

目的：在**同一块板子**上用官方 SDK 真实连一次 AP，证明「板子射频 ↔ AP」这条路是通的，并给自写运行时
（`s31-firmware` 跑同一个 Wi-Fi blob）留一个可以逐步复刻的 oracle。2026-11-25 靠它做的一次全量寄存器对照找到了
`s31-firmware` 侧 `esp_wifi_start` 不返回的根因（见下面的「全量寄存器 dump」）。

## 凭据

SSID 与密码走 `idf.py menuconfig` → `Oracle Wi-Fi credentials`（`main/Kconfig.projbuild`），**仓库里不带真实值**。
也可以在 `sdkconfig.defaults` 之后追加一个不入库的 `sdkconfig.defaults.local`：

```bash
cd tools/wifi-idf-oracle
idf.py --preview set-target esp32s31
idf.py menuconfig     # 填 SSID 与密码
idf.py build
```

## 烧录与抓取

```bash
cd build
IDF_PY=~/.espressif/python_env/idf6.1_py3.13_env/bin/python3
env -u LD_LIBRARY_PATH $IDF_PY -m esptool --chip esp32s31 -p /dev/ttyUSB0 -b 921600 write-flash @flash_args
# 复位后抓 60 秒
python3 ../capture.py   # 或 s31-firmware 的任意串口抓取工具，115200 8N1
```

烧录会覆盖 `0x2000`（bootloader）、`0x8000`（分区表）和 `0x10000`（factory 应用）。**测完必须把
`s31-firmware` 刷回去**（`firmware/tools/flash.sh` 会连同自己的 bootloader 与分区表一起写）：

```bash
cd s31-firmware && mkdir -p /tmp/default-image && sh scripts/build-image.sh firmware /tmp/default-image
cd firmware && sh tools/flash.sh /dev/ttyUSB0 /tmp/default-image/app.bin
```

## 2026-11-25 的结果（`logs/wifi-idf-oracle-sta.log`）

板子 ESP32-S31，AP 是用户提供的 OpenWrt 路由器（2.4 GHz、信道 1、WPA2-PSK；日志里有 BSSID，密码不入库）。

| 步骤 | 结果 |
| --- | --- |
| `esp_wifi_init` / `esp_wifi_set_mode` / `esp_wifi_set_config` / `esp_wifi_start` | 全部 `ESP_OK` |
| 状态机 | `init -> auth -> assoc -> run` |
| 关联 | `connected with hl-wifi, aid = 1, channel 1, BW20`；`STA_CONNECTED`，RSSI −28 dBm |
| DHCP | `GOT_IP`（网关 `192.168.31.1`） |
| ICMP | ping 网关 5 发 5 收 |
| ping 公网地址、经网关的 DNS | 没通（这台 AP 没有上联，或不对 ICMP / DNS 转发；与本板无关） |

从启动到拿到 IP 约 2.4 秒。主机自己的 Wi-Fi 看到的是同一个 BSSID、同一个信道（旁证）。

## 全量寄存器 dump（对照用）

`idf.py menuconfig` → `Oracle Wi-Fi credentials` → `Dump documented registers after esp_wifi_init / esp_wifi_start`
（`CONFIG_ORACLE_REGDUMP`，默认关）。打开后镜像在 `esp_wifi_init` 之后与 `esp_wifi_start` 之后各打印一遍 SoC 头文件里
定义过的 523 个寄存器（12 个外设块，只读），外加 `MAC_ST`（0x20104CAC，blob 私有的状态寄存器，不在头文件里）：

```text
REGDUMP after-init begin n=523 mac_st=00000000
REG 0 20109400 00000000
...
REGDUMP after-init end
```

地址表 `main/regdump_addrs.h` 由 `gen_regdump_addrs.py` 从 IDF 的 SoC 头文件生成，与 `s31-firmware` 探针侧的
`regdump_addrs`（`components/wifi-blobs/src/init_probe.zig`，`probe_regdump = true` 时同样打印）必须是同一张表：

```bash
python3 tools/wifi-idf-oracle/gen_regdump_addrs.py --check   # 核对头文件与 IDF 头文件一致，退出 0
python3 tools/wifi-idf-oracle/gen_regdump_addrs.py          # 重新生成
```

2026-11-25 的对照：`logs/wifi-idf-oracle-regdump-boot.log`（oracle）对 `logs/wifi-probe-regdump-before-boot.log`
（探针，修复前），差集 95 个；根因与实验见 `docs/adr/ADR-001-wifi-blobs-cooperative-yield.md` 文末。

连上并拿到地址之后（`CONFIG_ORACLE_WIFI_SSID` 非空时）还做两件事（2026-11-26 加，与 `s31-firmware` 真实链路探针的连接与
数据通路阶段对照）：ping 网关之后打一行 `ORACLESTATS after gateway ping` 与驱动的省电 / 收发统计
（`esp_wifi_statis_dump(WIFI_STATIS_PS | WIFI_STATIS_RXTX)`）；打开 `CONFIG_ORACLE_REGDUMP` 时在连上之后、ping 之前再取一份
全量快照（`REGDUMP connected begin`）——四次握手之后数据帧靠 MAC 里的密钥表加解密，这一层的差别只在连接态看得到。

## 只扫描不连接（2026-11-26）

`CONFIG_ORACLE_WIFI_SSID` 留空时不连接：`esp_wifi_start` 之后非阻塞地起一次全信道扫描，等扫描结束，再打印扫到的
若干个 AP（`ssid`、`bssid`、`ch`、`rssi`、`auth`）：

```text
oracle: esp_wifi_scan_start(NULL, nonblock) -> ESP_OK
oracle: SCAN_DONE status=0 number=36 scan_id=128
oracle: esp_wifi_scan_get_ap_num -> ESP_OK n=36
oracle: ap[0] ssid=... bssid=... ch=1 rssi=-29 auth=WPA2_PSK
```

`s31-firmware` 的真实链路探针（`-Dwifi-link-probe`）在同一点做同样的输出，两边逐 AP 对照；对照的结论与入库的那一侧
（`logs/wifi-link-scan-boot.log`，已脱敏）见 `docs/verification/wifi-ieee80211-verification.md` §10。
**oracle 这一侧的扫描日志没有入库**（里面是邻居的 SSID 与 BSSID）。

打开 `CONFIG_ORACLE_REGDUMP` 时，扫描开始后 100 ms 另打四种 dump（都只读，只用于诊断）：

| 前缀 | 内容 |
| --- | --- |
| `FOCUSDUMP in-scan` | 定点采样：全量对照里出现过差异的那几十个地址，一个一行（`FOCUS <地址> <值>`）。**在所有慢 dump 之前**打——全量 dump 一遍要十几秒，等轮到它时扫描早已结束、驱动把 FE / BB 的时钟收起来了，那是空闲态而不是收发态 |
| `REGDUMP in-scan` / `MACDUMP in-scan` | 同上面的 523 个寄存器；外加 MAC 块整段（0x20104000 起 4 KB，blob 私有，不在头文件里；个别读清位会被读掉） |
| `RG <地址> …` | 不在头文件里的几块：FE（0x20100000 起 16 KB）、BB / BRX / MODEM_TIMER / ETM / DATADUMP / WIDGETS（0x20107000 起 11 KB）、0x2010D000 起 8 KB；每行 8 个字，全打不过滤 |
| `CHMDUMP` | 驱动的信道管理器（blob 的 `g_chm`）：目标信道、驱动记的当前信道等 |

不要把这些 dump 放在时序敏感的点之后。另外 `readtiming` 打每个地址读 16 次的平均耗时，与探针侧的 `busReadTiming` 对照。

## 判读纪律

- 这是**厂商栈**的结果（L4），不是 `s31-firmware` 的结果。`s31-firmware` 的 Zig 移植没有用到这里的任何一行代码。
- 对照的用法：在同一时点（`esp_wifi_init` 之前 / 之后、`esp_wifi_start` 之后）比较寄存器与 osi 调用序列，
  见 `docs/verification/wifi-ieee80211-verification.md`。
