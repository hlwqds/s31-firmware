#!/usr/bin/env bash
# 本地一键门禁：fmt → 单元测试 → 覆盖率 → E2E(host)
#
# 解释器不写死：本机默认 python3 可能既没有 PyYAML 也没有 pyserial，
# 而 store 里的包是按具体小版本编的。用法：
#   PYTHON=/nix/store/.../python3.14 \
#   PYTHONPATH=/nix/store/...-pyyaml.../lib/python3.14/site-packages:/nix/store/...-pyserial.../lib/python3.14/site-packages \
#   ZIG=/tmp/bin/zig ESPTOOL=/nix/store/.../bin/esptool scripts/check-all.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHON=${PYTHON:-python3}
export PYTHON
scripts/check-fmt.sh
"$PYTHON" scripts/check-yaml.py
"$PYTHON" scripts/check-invariants.py
scripts/check-host.sh
"$PYTHON" scripts/check-coverage.py
"$PYTHON" tools/s31-production/baseline/update_matrix.py --check
"$PYTHON" scripts/check-capacity.py
mkdir -p reports
ESPTOOL=${ESPTOOL:-python -m esptool} "$PYTHON" tests/e2e/run_e2e.py --host --junit reports/e2e-host.xml
