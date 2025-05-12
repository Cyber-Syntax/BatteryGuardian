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

  # Main loop
  while true; do
    # Get the battery percentage with error checking
    local battery_percent
    battery_percent=$(bg_check_battery)
    if [[ ! "$battery_percent" =~ ^[0-9]+$ ]]; then
      bg_error "Invalid battery percentage: '$battery_percent'. Using previous value: $previous_battery_percent"
      battery_percent=$previous_battery_percent
    fi

    # Get AC status with error checking
    local ac_status
    ac_status=$(bg_check_ac_status)
    if [[ "$ac_status" != "Charging" && "$ac_status" != "Discharging" ]]; then
      bg_warn "Unrecognized AC status: '$ac_status'. Using previous value: $previous_ac_status"
      ac_status=$previous_ac_status
    fi

    # Log current status (only if changed to reduce log size)
    if [ "$battery_percent" != "$previous_battery_percent" ] || [ "$ac_status" != "$previous_ac_status" ]; then
      bg_info "Battery: $battery_percent%, AC: $ac_status"
    fi

    # Handle AC connection state changes
    if [ "$ac_status" == "Charging" ] && [ "$previous_ac_status" != "Charging" ]; then
      bg_info "AC power connected."
      bg_send_notification "Battery Info" "AC power connected." "normal"
      # Set brightness to high when AC is connected
      bg_set_brightness "$bg_BRIGHTNESS_HIGH"
    elif [ "$ac_status" == "Discharging" ] && [ "$previous_ac_status" == "Charging" ]; then
      bg_info "AC power disconnected."
      bg_send_notification "Battery Info" "AC power disconnected." "normal"
      # Adjust brightness immediately when switching to battery
      bg_adjust_brightness_for_battery "$battery_percent" "$ac_status"
    fi

    # Check battery levels and issue notifications if needed
    if bg_should_send_notification "$battery_percent" "$ac_status"; then
      bg_send_battery_notification "$battery_percent" "$ac_status"
    fi

    # Take critical actions for extremely low battery
    if [ "$battery_percent" -le 5 ] && [ "$ac_status" == "Discharging" ]; then
      # Send emergency notification
      bg_send_notification "CRITICAL BATTERY LEVEL" "Battery at $battery_percent%! System may shut down soon!" "critical"

      # Log the critical state
      bg_error "CRITICAL: Battery at $battery_percent%. Taking emergency actions."

      # Optional: Trigger system actions (hibernation/suspension)
      # Uncomment the appropriate line for your system if desired

      # For systemd systems:
      # if bg_check_command_exists "systemctl"; then
      #   bg_info "Attempting to hibernate system due to critical battery level"
      #   systemctl hibernate || systemctl suspend
      # fi

      # For non-systemd systems:
      # if bg_check_command_exists "pm-hibernate"; then
      #   bg_info "Attempting to hibernate system due to critical battery level"
      #   pm-hibernate || pm-suspend
      # fi
    fi

    # Adjust brightness based on battery percentage
    bg_adjust_brightness_for_battery "$battery_percent" "$ac_status"

    # Determine sleep duration based on battery status
    local sleep_duration
    sleep_duration=$(bg_get_sleep_duration "$battery_percent" "$ac_status")
    # Validate sleep duration
    if [[ ! "$sleep_duration" =~ ^[0-9]+$ ]] || [ "$sleep_duration" -lt 30 ]; then
      bg_warn "Invalid sleep duration: '$sleep_duration'. Using safe default of 60 seconds."
      sleep_duration=60
    fi

    # Update previous values
    previous_ac_status="$ac_status"
    previous_battery_percent="$battery_percent"

    # Sleep before checking again
    bg_info "Sleeping for $sleep_duration seconds."
    sleep "$sleep_duration"
  done
}

# Start the main function
bg_main

