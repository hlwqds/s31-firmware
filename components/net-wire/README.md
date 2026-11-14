# net-wire：生产固件的真实链路探针

`-Dwire=true` 才会编入；默认 `net`/`wifi`/`tls`/`full` profile 不包含它。

## 做什么

1. 复用 `net-ethernet` 的 EMAC bring-up（APM、YT8531 RGMII delay、APLL）；
2. 用 `net-udp-dhcp-dns` 发 DHCP DISCOVER/OFFER/REQUEST/ACK；
3. 用 `net-tcp` 的 `tcp.Conn` 向租约网关的 9000 端口主动打开：`activeOpen` 发
   SYN，收到的段喂 `onSegment`，每轮 `tick` 处理 RTO 重传；进 ESTABLISHED 后
   立刻 RST（保持 profile 短，不走 FIN/TIME_WAIT）。

没有 DHCP 应答时打印 `wire: skipped/no-dhcp-server` 并返回成功（优雅跳过），
不会拖红默认板级 E2E。

## 主机前置

```bash
# 1) dnsmasq / NetworkManager shared 已在 10.42.0.1 提供 DHCP
# 2) 临时放行 UDP 67/53 与 TCP 9000（测试后删除）
sudo iptables -I INPUT 1 -i enp0s31f6 -p udp --dport 67 -j ACCEPT
sudo iptables -I INPUT 2 -i enp0s31f6 -p udp --dport 53 -j ACCEPT
sudo iptables -I INPUT 3 -i enp0s31f6 -p tcp --dport 9000 -j ACCEPT
# 3) 监听 TCP 9000
python3 -m http.server 9000     # 或任意 accept 脚本
```

## 验证

```bash
cd ~/code/s31-firmware
ZIG=/nix/store/...-zig-0.17.1/bin/zig env -u LD_LIBRARY_PATH \
  python3 tests/e2e/run_e2e.py --host
ZIG=... python3 tests/e2e/run_e2e.py --board --profile net-wire
```

2026-11-15 实测（`tcp.Conn` 版）：DHCP 租约 `10.42.0.139`，板侧
`wire: tcp SYN sent iss=0x20263111` →
`wire: tcp ESTABLISHED state=ESTABLISHED snd_una=0x20263112 rcv_nxt=0xeeaeab06`
→ `wire: tcp RST sent`，`wire: checks passed=4 failed=0`；主机 accept 到
`10.42.0.139:40000`，随后 `Connection reset by peer`（RST，符合预期）。
日志 `logs/e2e-net-wire-boot.log`。
