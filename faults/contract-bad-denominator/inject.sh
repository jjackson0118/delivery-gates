#!/usr/bin/env bash
# Synthetic gates are built by the fault rather than shipped, because these are
# defects in the contract library, not in any repository under test.
set -euo pipefail
mkdir -p .synthetic
cat > .synthetic/gate.sh <<'INNER'
#!/usr/bin/env bash
source "$GATE_LIB"
gate_init "_synthetic" "things"
gate_tool "synthetic"
gate_scanned ""
gate_finish
INNER
chmod +x .synthetic/gate.sh
