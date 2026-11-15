#!/usr/bin/env bash
# 本地一键门禁：fmt → 单元测试 → 覆盖率 → E2E(host)
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check-fmt.sh
python3 scripts/check-yaml.py
python3 scripts/check-invariants.py
scripts/check-host.sh
python3 scripts/check-coverage.py
python3 tools/s31-production/baseline/update_matrix.py --check
mkdir -p reports
ESPTOOL=${ESPTOOL:-python -m esptool} python3 tests/e2e/run_e2e.py --host --junit reports/e2e-host.xml
