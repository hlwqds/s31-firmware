#!/usr/bin/env bash
# 重新生成 BLE controller 的链接闭包对象清单（`-Dbt-blob-objs` 要的那串）。
#
# 之前这份清单只存在于 /tmp，换台机器镜像就编不出来。这个脚本把整条配方固化：
#   1) 解包 4 个归档
#   2) 从**归档定义的根**出发做符号图 BFS
#   3) 减 ROM（主文件 `esp32s31.rom.ld` + 全部 `esp32s31.rom.*.ld`；注意裸赋值形式）
#   4) 打印逗号清单、每个对象的段字节、以及可直接复制的构建命令
#
# 产物目录默认 /tmp/bt_all（已被 .gitignore 覆盖，不入库）。
set -euo pipefail
OUT=${1:-/tmp/bt_all}
IDF=${IDF_PATH:-$HOME/esp/esp-idf}
TOOLS=$(ls -d ~/.espressif/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin | head -1)

rm -rf "$OUT"; mkdir -p "$OUT"
AR="$TOOLS/riscv32-esp-elf-ar"
for a in \
  "$IDF/components/bt/controller/lib_esp32s31/esp32s31-bt-lib/libble_app.a" \
  "$IDF/components/bt/controller/lib_esp32s31/esp32s31-bt-lib/libbtdm_common.a" \
  "$IDF/components/esp_phy/lib/esp32s31/libbtbb.a" \
  "$IDF/components/esp_phy/lib/esp32s31/libphy.a" ; do
  [ -f "$a" ] || { echo "missing archive: $a" >&2; exit 1; }
  d="$OUT/$(basename "$a" .a)"; mkdir -p "$d"; ( cd "$d" && "$AR" x "$a" )
done

"$TOOLS/riscv32-esp-elf-python3" --version >/dev/null 2>&1 || true
python3 - "$OUT" "$TOOLS" "$IDF" <<'PY'
import collections, pathlib, re, subprocess, sys

out = pathlib.Path(sys.argv[1]); tools = sys.argv[2]
NM = f"{tools}/riscv32-esp-elf-nm"

# 根：都必须是**归档里定义**的入口（porting 层 C 里的同名函数不在归档，不能当根）
# 根集合 = **我们的 Zig 代码直接调用的每一个归档符号**。
# 少一个就会出现"链接期 undefined"（符号在归档里，但没被拉进闭包）——实测踩过。
ROOTS = [
    # 任务 / 流控
    "r_btdm_task_init", "r_btdm_task_enable", "r_btdm_task_disable", "r_btdm_task_deinit",
    "r_btdm_hci_fc_env_init", "r_btdm_hci_fc_enable",
    # BLE 控制器与两个 stack
    "r_ble_controller_init", "esp_ble_register_bb_funcs",
    "r_base_stack_initEnv", "r_conn_stack_initEnv",
    "r_base_stack_enable", "r_conn_stack_enable",
    # 公有地址
    "r_esp_ble_ll_set_public_addr",
    # msys / ext_funcs
    "r_esp_ble_msys_init", "esp_register_ext_funcs",
    # HCI 传输（A 路径）
    "r_btdm_hci_trans_buf_alloc", "r_btdm_hci_trans_buf_free",
    "r_btdm_hci_pkt_flag_ble_setf", "r_btdm_hci_trans_rx",
    "r_btdm_hci_trans_register_tx",
    # HCI 传输（B 路径）
    "r_ble_hci_trans_cfg_hs", "r_ble_hci_trans_buf_alloc",
    "r_ble_hci_trans_hs_cmd_tx", "r_ble_hci_trans_buf_free",
]

objs = sorted(str(p) for p in out.rglob("*.o"))
defs, undef = {}, {}
for o in objs:
    d = {l.split()[2] for l in subprocess.run([NM, "--defined-only", o], capture_output=True, text=True).stdout.splitlines() if len(l.split()) >= 3}
    u = {l.split()[-1] for l in subprocess.run([NM, "--undefined-only", o], capture_output=True, text=True).stdout.splitlines() if l.split()}
    defs[o], undef[o] = d, u

sym2obj = collections.defaultdict(list)
for o, d in defs.items():
    for s in d:
        sym2obj[s].append(o)

missing_roots = [r for r in ROOTS if r not in sym2obj]
if missing_roots:
    print("WARN roots not in archives:", missing_roots, file=sys.stderr)

seen, q = set(), collections.deque()
for r in ROOTS:
    for o in sym2obj.get(r, []):
        q.append(o)
while q:
    o = q.popleft()
    if o in seen:
        continue
    seen.add(o)
    for s in undef[o]:
        for o2 in sym2obj.get(s, []):
            if o2 not in seen:
                q.append(o2)

# 减 ROM：主文件 + 全部变体，两种赋值形式都收
rom = set()
romdir = pathlib.Path(sys.argv[3]) / "components/esp_rom/esp32s31/ld"
for f in sorted(romdir.glob("esp32s31.rom*.ld")):
    for line in f.read_text().splitlines():
        m = re.match(r"\s*([A-Za-z_]\w*)\s*=\s*0x", line) or re.match(r"\s*PROVIDE\s*\(\s*([A-Za-z_]\w*)", line)
        if m:
            rom.add(m.group(1))

rest = sorted({s for o in seen for s in undef[o]} - sym2obj.keys() - rom)
byfam = collections.Counter(o.split("/")[-2] if "/" in o else "?" for o in seen)

# 展平成 single dir 供 -Dbt-blob-dir 使用
flat = out / "flat"
flat.mkdir(exist_ok=True)
names = []
for o in sorted(seen):
    dst = flat / pathlib.Path(o).name.replace(str(out).strip("/").replace("/", "_") + "_", "")
    dst = flat / (pathlib.Path(o).parent.name + "_" + pathlib.Path(o).name)
    dst.write_bytes(pathlib.Path(o).read_bytes())
    names.append(dst.name)

csv = ",".join(sorted(names))
(flat / "objs.csv").write_text(csv + "\n")
(flat / "unresolved.txt").write_text("\n".join(rest) + "\n")

print(f"objects: {len(objs)}  closure: {len(seen)}  by archive: {dict(byfam)}")
print(f"unresolved after ROM: {len(rest)}")
for s in rest:
    print("   ", s)
print()
print("build with:")
print(f"  zig build -Dtarget=riscv32-freestanding-eabihf \\")
print(f"    -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \\")
print(f"    -Dbt-blob-dir={flat} -Dbt-blob-objs=$(cat {flat}/objs.csv)")
PY
