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

## 判读纪律

- 这是**厂商栈**的结果（L4），不是 `s31-firmware` 的结果。`s31-firmware` 的 Zig 移植没有用到这里的任何一行代码。
- 对照的用法：在同一时点（`esp_wifi_init` 之前 / 之后、`esp_wifi_start` 之后）比较寄存器与 osi 调用序列，
  见 `docs/verification/wifi-ieee80211-verification.md`。
