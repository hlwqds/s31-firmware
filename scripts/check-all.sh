#!/usr/bin/env bash
# 本地一键门禁：fmt → 单元测试 → 覆盖率 → E2E(host)
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check-fmt.sh
scripts/check-host.sh
python3 scripts/check-coverage.py
mkdir -p reports
ESPTOOL=${ESPTOOL:-python -m esptool} python3 tests/e2e/run_e2e.py --host --junit reports/e2e-host.xml
