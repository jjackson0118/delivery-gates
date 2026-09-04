#!/usr/bin/env bash
# One byte. A real backdoor would be larger and would still be a binary diff
# that renders in review as "Binary file not shown".
set -euo pipefail
printf '\x00' >> gradle/wrapper/gradle-wrapper.jar
