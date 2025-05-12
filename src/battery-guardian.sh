#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Entry point script for easy execution
# Author: Cyber-Syntax
# License: BSD 3-Clause License
# --------------------------------------------------------

# Ensure script exits on errors and undefined variables
set -o errexit -o nounset -o pipefail

# Determine the absolute path to this script
BG_BASE_DIR=""
BG_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BG_BASE_DIR
export BG_BASE_DIR

# Execute the main script
exec "$BG_BASE_DIR/src/main.sh" "$@"
