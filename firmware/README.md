# firmware

单一固件：`src/start.zig`（板级启动 + FPU/看门狗）→ `src/main.zig`（按特性开关顺序执行子系统自检）。

- 特性开关：`-Dboot -Dnet -Dtls -Dapps -Dwifi`（默认 `boot+net`）
- 构建：`zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall`
- 镜像：`esptool elf2image` → `image-info` 必须恰好两行 `DROM, IROM`
- 烧录：`idf-bootstrap/` 先跑一次 `idf.py build`，然后 `tools/flash.sh /dev/ttyUSB1`
- 板侧输出：`firmware: checks: passed=N failed=M total=K` + `main: verdict=pass|fail`

限制：TLS 与 Wi-Fi 同时开启会超出两段镜像窗口，见 `ROADMAP.md` P0.2。
