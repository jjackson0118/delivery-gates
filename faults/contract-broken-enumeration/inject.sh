#!/usr/bin/env bash
# A directory the gate cannot read, containing a file it would have flagged.
# Permission errors mid-enumeration are ordinary in CI: a mounted cache, a
# root-owned artifact directory, a stale container volume.
set -euo pipefail
mkdir -p sub/secret
cat > sub/secret/bad.sh <<'INNER'
#!/usr/bin/env bash
cd /nowhere
rm -rf ./build
INNER
chmod 000 sub/secret
