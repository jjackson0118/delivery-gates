#!/usr/bin/env bash
# Adds a script whose cd is unchecked and which does NOT set -e.
#
# The distinction matters and shellcheck knows it: under `set -e` a failed cd
# aborts the script, so SC2164 is correctly suppressed. Without it, cd fails,
# execution continues in whatever directory the script was already in, and the
# rm below deletes a build directory somewhere else entirely. The first version
# of this fault included `set -euo pipefail` and therefore planted a script
# with no defect in it -- a fault that was not a fault, which the harness
# reported as an uncaught fault rather than as a green pass.
set -euo pipefail
mkdir -p ci
cat > ci/_fault-planted.sh <<'INNER'
#!/usr/bin/env bash
cd /tmp/some-workspace
rm -rf ./build
INNER
chmod +x ci/_fault-planted.sh
