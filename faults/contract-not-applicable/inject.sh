#!/usr/bin/env bash
# Removes every declaration of a JVM build. What remains is a repository the
# JVM gates have no business judging.
set -euo pipefail
rm -f gradlew gradlew.bat build.gradle.kts settings.gradle.kts pom.xml
rm -rf gradle/wrapper
