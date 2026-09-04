#!/usr/bin/env bash
# Verifies the Gradle wrapper is authentic before it is allowed to run.
#
# gradle-wrapper.jar is ~43KB of opaque bytecode, committed to source control,
# executed on every developer machine and every CI runner before a single line
# of project code compiles. GitHub renders a pull request that swaps it as
# "Binary file not shown", so no review has ever read it. It is the highest
# leverage place to put a backdoor in a JVM repository.
#
# Three things are checked, because validating the jar alone leaves two holes:
#
#   1. gradle-wrapper.jar against Gradle's published checksums.
#   2. gradlew and gradlew.bat, which are NOT covered by Gradle's checksum
#      service, are also executed first, and are also unread in review.
#   3. distributionSha256Sum is present in gradle-wrapper.properties. Validating
#      the launcher says nothing about the distribution the launcher then
#      downloads. validateDistributionUrl only checks the URL looks like
#      gradle.org, and a URL shape is not integrity.
#
# Expected checksums live in .gates/wrapper-checksums.txt in the repo under
# test, so a change to the launcher scripts is a reviewable diff rather than a
# silent substitution.

SCRIPT_DIR="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gate.sh
source "$SCRIPT_DIR/../lib/gate.sh" || {
    printf 'FATAL: cannot load the gate contract from %s\n' "$SCRIPT_DIR/../lib/gate.sh" >&2
    exit 2
}

gate_init "gradle-wrapper" "wrapper files"
gate_tool "sha256sum + services.gradle.org checksum API"

TARGET="${1:-.}"
cd "$TARGET" || gate_error "cannot enter $TARGET"

JAR="gradle/wrapper/gradle-wrapper.jar"
PROPS="gradle/wrapper/gradle-wrapper.properties"

[ -f "$JAR" ]   || gate_error "no $JAR -- nothing to verify, and a build that needs one"
[ -f "$PROPS" ] || gate_error "no $PROPS"

require_cmd sha256sum
require_cmd curl

scanned=0

# --- 1. the wrapper jar, against Gradle's published checksums ---------------
jar_sha=$(sha256sum "$JAR" | cut -d' ' -f1)
scanned=$(( scanned + 1 ))

gradle_version=$(sed -n 's|.*gradle-\([0-9.]*\)-bin\.zip.*|\1|p' "$PROPS" | head -1)
[ -n "$gradle_version" ] || gate_error "could not determine Gradle version from $PROPS"

published=$(curl -sSfL --retry 3 \
    "https://services.gradle.org/versions/all" \
    | grep -o "\"wrapperChecksumUrl\"[^,]*gradle-${gradle_version}-wrapper.jar.sha256" \
    | head -1 | sed 's|.*"https|https|;s|"$||') || true

if [ -n "$published" ]; then
    want=$(curl -sSfL --retry 3 "$published" | tr -d '[:space:]')
    if [ "$jar_sha" != "$want" ]; then
        gate_finding "wrapper-jar-checksum-mismatch"
        printf '   gradle-wrapper.jar sha256 %s != published %s\n' "$jar_sha" "$want" >&2
    fi
else
    gate_error "could not retrieve published checksum for Gradle $gradle_version -- unverified is not verified"
fi

# --- 2. the launcher scripts, which Gradle does not publish checksums for ----
EXPECTED=".gates/wrapper-checksums.txt"
if [ -f "$EXPECTED" ]; then
    while read -r want file; do
        if [ -z "${want:-}" ]; then continue; fi
        case "$want" in \#*) continue ;; esac
        [ -f "$file" ] || { gate_finding "launcher-missing:$file"; continue; }
        scanned=$(( scanned + 1 ))
        got=$(sha256sum "$file" | cut -d' ' -f1)
        if [ "$got" != "$want" ]; then
            gate_finding "launcher-checksum-mismatch:$file"
            printf '   %s sha256 %s != expected %s\n' "$file" "$got" "$want" >&2
        fi
    done < "$EXPECTED"
else
    gate_finding "no-launcher-checksums"
    printf '   %s absent -- gradlew and gradlew.bat execute unverified\n' "$EXPECTED" >&2
fi

# --- 3. the distribution the launcher will fetch -----------------------------
scanned=$(( scanned + 1 ))
if ! grep -q '^distributionSha256Sum=' "$PROPS"; then
    gate_finding "no-distribution-checksum"
    printf '   %s has no distributionSha256Sum; validateDistributionUrl checks URL shape, not integrity\n' "$PROPS" >&2
fi

gate_scanned "$scanned"
gate_finish
