#!/usr/bin/env bash
set -euo pipefail
mkdir -p .synthetic
cat > .synthetic/gate.sh <<'INNER'
#!/usr/bin/env bash
source "$GATE_LIB"
gate_init "_synthetic" "things"
gate_tool "synthetic"
gate_scanned 5
echo "$THIS_VARIABLE_IS_NOT_SET"
gate_finish
INNER
chmod +x .synthetic/gate.sh
