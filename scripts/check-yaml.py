#!/usr/bin/env python3
"""校验 .github/workflows/*.yml 与仓库内 YAML（防止未加引号的 `: ` 把 workflow 写坏）。

依赖 PyYAML；CI 的 host job 会先 `python3 -m pip install pyyaml`。
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("需要 PyYAML：python3 -m pip install pyyaml\n"
          "  没有 pip（NixOS）时换解释器：PYTHON=<带 pyyaml 的 python> "
          "PYTHONPATH=<...-pyyaml/lib/python3.X/site-packages> scripts/check-all.sh",
          file=sys.stderr)
    raise SystemExit(2)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    files = sorted((root / ".github").rglob("*.yml")) + sorted((root / ".github").rglob("*.yaml"))
    files += sorted(root.glob("*.yml")) + sorted(root.glob("*.yaml"))
    failed = 0
    for f in files:
        try:
            yaml.safe_load(f.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            print(f"YAML FAIL: {f.relative_to(root)}: {exc}", file=sys.stderr)
            failed += 1
    if failed:
        return 1
    print(f"yaml: OK ({len(files)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
