#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Utility functions for general operations
# Author: Cyber-Syntax
# License: BSD 3-Clause License
# --------------------------------------------------------

# Ensure script exits on errors and undefined variables when sourced directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -o errexit -o nounset -o pipefail
fi

# Check if required modules are loaded, source them if needed 
if ! command -v bg_error >/dev/null 2>&1 || ! command -v bg_warn >/dev/null 2>&1; then
  # Get the script directory
  BG_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$BG_MODULE_DIR/log.sh"
fi

# Check if a command exists in the system
bg_check_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check for required dependencies
bg_check_dependencies() {
  local missing_deps=0

  # Check for notify-send (required)
  if ! bg_check_command_exists "notify-send"; then
    bg_warn "Missing required dependency: notify-send"
    bg_warn "Please install a notification daemon like dunst or libnotify"
    missing_deps=$((missing_deps + 1))
  fi

  # Check for at least one brightness control method
  if ! bg_check_command_exists "brightnessctl" && ! bg_check_command_exists "light" && ! bg_check_command_exists "xbacklight"; then
    bg_warn "No brightness control tool found (brightnessctl, light, or xbacklight)"
    bg_warn "Brightness control will fall back to direct sysfs access if available"
  fi

  return $missing_deps
}

# Check if another instance is running and create a lock
bg_check_lock() {
  # Check if lock file exists
  if [[ -f "$BG_LOCK_FILE" ]]; then
    # Try to read the PID from the lock file
    local pid
    if pid=$(cat "$BG_LOCK_FILE" 2>/dev/null); then
      # Check if process with this PID still exists
      if kill -0 "$pid" 2>/dev/null; then
        bg_warn "Another instance is already running with PID $pid"
        exit 1
      else
        bg_warn "Found stale lock file. Previous process (PID $pid) no longer exists."
      fi
    fi
  fi

  # Create lock file with current PID
  echo "$$" > "$BG_LOCK_FILE" || {
    bg_error "Failed to create lock file at $BG_LOCK_FILE"
    exit 1
  }

  # Register cleanup handler to remove lock file when script exits
  trap 'rm -f "$BG_LOCK_FILE"; exit $?' EXIT HUP INT TERM
}

# Get sleep duration based on battery status
bg_get_sleep_duration() {
  local battery_percent=$1
  local ac_status=$2
  local duration=300 # Default: 5 minutes

  # If charging, check less frequently
  if [ "$ac_status" == "Charging" ]; then
    duration=600 # 10 minutes
  else
    # When discharging, check more frequently for lower battery levels
    if [ "$battery_percent" -le 5 ]; then
      duration=60 # 1 minute
    elif [ "$battery_percent" -le 10 ]; then
      duration=120 # 2 minutes
    elif [ "$battery_percent" -le 20 ]; then
      duration=180 # 3 minutes
    elif [ "$battery_percent" -le 50 ]; then
      duration=300 # 5 minutes
    else
      duration=600 # 10 minutes
    fi
  fi

  echo "$duration"
}
