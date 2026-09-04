#!/usr/bin/env bash
# Makes gradle-wrapper.properties unreadable. The gate's existence check ([ -f ])
# still passes, so it proceeds and the sed that parses the file fails -- an
# unhandled failure partway through, which is the realistic shape of this bug.
# Permissions are not a hypothetical cause: a root-owned node_modules once made
# an entire preflight suite unrunnable on a production checkout.
set -euo pipefail
chmod 000 gradle/wrapper/gradle-wrapper.properties
