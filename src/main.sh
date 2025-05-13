#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Main entry point for battery monitoring application
# Author: Cyber-Syntax
# License: BSD 3-Clause License
# --------------------------------------------------------

# Ensure script exits on errors and undefined variables
set -o errexit -o nounset -o pipefail

# ---- Define paths ----
# Determine the absolute path to this script
BG_SCRIPT_DIR=""
BG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BG_SCRIPT_DIR

# BG_PARENT_DIR is used to reference files in the parent directory (like configs)
BG_PARENT_DIR=""
BG_PARENT_DIR="$(dirname "$BG_SCRIPT_DIR")"
readonly BG_PARENT_DIR
export BG_PARENT_DIR

# Setup cleanup trap
cleanup() {
  local exit_code=$?
  bg_info "Battery Guardian shutting down with exit code: $exit_code"
  
  # Remove lock file if it exists and belongs to this process
  if [[ -f "$BG_LOCK_FILE" ]]; then
    local lock_pid
    lock_pid=$(cat "$BG_LOCK_FILE" 2>/dev/null) || true
    if [[ "$lock_pid" == "$$" ]]; then
      rm -f "$BG_LOCK_FILE"
      bg_info "Lock file removed"
    fi
  fi
  
  exit "$exit_code"
}

trap 'cleanup; exit $?' EXIT INT TERM HUP

# ---- Load modules in the correct order ----
source "$BG_SCRIPT_DIR/modules/log.sh"
source "$BG_SCRIPT_DIR/modules/utils.sh"
source "$BG_SCRIPT_DIR/modules/config.sh"
source "$BG_SCRIPT_DIR/modules/battery.sh"
source "$BG_SCRIPT_DIR/modules/brightness.sh"
source "$BG_SCRIPT_DIR/modules/notification.sh"

# ---- Main Function ----
bg_main() {
  # Log the start of the script
  bg_info "Battery Guardian started"

  # Check dependencies
  bg_check_dependencies

  # Check lock before proceeding
  bg_check_lock

  # Check if a battery is present
  if ! bg_check_battery_exists; then
    bg_error "No battery detected. Exiting."
    exit 0
  fi

  # Load configuration
  bg_load_config

  # Initialize variables
  local previous_ac_status="Unknown"
  local previous_battery_percent=0

  # Export previous variables so they're accessible in the monitoring functions
  export previous_battery_percent=$previous_battery_percent
  export previous_ac_status=$previous_ac_status
  
  # Start event-based monitoring instead of using polling loop
  bg_info "Starting event-based battery monitoring..."
  start_monitoring
  
  # If start_monitoring somehow exits (should not happen), fall back to traditional loop
  bg_warn "Event-based monitoring exited unexpectedly. Falling back to polling loop."
  
  # Main fallback loop with adaptive back-off
  local prev_bat_percent=${previous_battery_percent:-0}
  local prev_ac=${previous_ac_status:-"Unknown"}
  local has_changed=1  # Start with 1 to force initial reset of back-off
  
  while true; do
    # Call the consolidated check function
    check_battery_and_adjust_brightness
    
    # Detect if status has changed
    if [[ "$prev_bat_percent" != "$previous_battery_percent" || "$prev_ac" != "$previous_ac_status" ]]; then
      has_changed=1
    else
      has_changed=0
    fi
    
    # Get sleep duration based on status and change detection
    local sleep_duration
    sleep_duration=$(bg_get_sleep_duration "$previous_battery_percent" "$previous_ac_status" "$has_changed")
    
    # Validate sleep duration
    if [[ ! "$sleep_duration" =~ ^[0-9]+$ ]] || [ "$sleep_duration" -lt 10 ]; then
      bg_warn "Invalid sleep duration: '$sleep_duration'. Using safe default of 30 seconds."
      sleep_duration=30
    fi
    
    # Update previous values for next comparison
    prev_bat_percent=$previous_battery_percent
    prev_ac=$previous_ac_status

    # Sleep before checking again
    bg_info "Sleeping for ${sleep_duration}s (adaptive back-off)"
    sleep "$sleep_duration"
  done
      
}

# Start the main function
bg_main

