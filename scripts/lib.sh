#!/usr/bin/env bash
# Definitions shared by the scripts in this directory. Source it after
# `set -euo pipefail`. It defines `root` (this checkout) and declares
# functions; it runs no commands and changes no directory.
# shellcheck disable=SC2034  # read by sourcing scripts
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() { if "$@" > /dev/null 2>&1; then fail "unexpected success: $*"; fi; }
