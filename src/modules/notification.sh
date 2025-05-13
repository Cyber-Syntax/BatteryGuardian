#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Notification functions module
# Author: Cyber-Syntax
# License: BSD 3-Clause License
# --------------------------------------------------------

# Ensure script exits on errors and undefined variables when sourced directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -o errexit -o nounset -o pipefail
fi

# Check if required modules are loaded, source them if needed 
if ! command -v bg_error >/dev/null 2>&1; then
  # Get the script directory
  BG_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$BG_MODULE_DIR/log.sh"
fi

if ! command -v bg_check_command_exists >/dev/null 2>&1; then
  BG_MODULE_DIR="${BG_MODULE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  source "$BG_MODULE_DIR/utils.sh"
fi

# Load config variables if they don't exist
if [[ -z "${bg_CRITICAL_THRESHOLD:-}" || -z "${bg_LOW_THRESHOLD:-}" || -z "${bg_FULL_BATTERY_THRESHOLD:-}" || -z "${bg_NOTIFICATION_COOLDOWN:-}" ]]; then
  # Try loading from defaults first
  bg_parent_dir=""
  if [[ -n "${BG_PARENT_DIR:-}" ]]; then
    bg_parent_dir="$BG_PARENT_DIR"
  else
    bg_parent_dir="$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")"
  fi
  
  if [[ -f "$bg_parent_dir/configs/defaults.sh" ]]; then
    source "$bg_parent_dir/configs/defaults.sh"
  else
    # Fallback to default values
    bg_CRITICAL_THRESHOLD=10
    bg_LOW_THRESHOLD=20
    bg_FULL_BATTERY_THRESHOLD=90
    bg_NOTIFICATION_COOLDOWN=300
  fi
fi

# Add throttling functions
bg_should_throttle() {
  local notification_type="$1"
  local throttle_dir
  
  # Set up directories for timestamp files
  XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
  throttle_dir="${XDG_STATE_HOME}/battery-guardian/notifications"
  
  # Create directory if it doesn't exist
  mkdir -p "$throttle_dir" 2>/dev/null
  
  local timestamp_file="$throttle_dir/${notification_type}_timestamp"
  
  # If timestamp file doesn't exist, no throttling needed
  if [[ ! -f "$timestamp_file" ]]; then
    return 0 # Not throttled
  fi
  
  # Read the last notification timestamp
  local last_timestamp
  last_timestamp=$(cat "$timestamp_file" 2>/dev/null)
  if [[ ! "$last_timestamp" =~ ^[0-9]+$ ]]; then
    # Invalid timestamp, allow notification
    return 0
  fi
  
  # Get current time
  local current_time
  current_time=$(date +%s)
  
  # Calculate time difference
  local time_diff=$((current_time - last_timestamp))
  
  # If time difference is less than cooldown, throttle notification
  if [[ "$time_diff" -lt "${bg_NOTIFICATION_COOLDOWN:-300}" ]]; then
    return 1 # Throttled
  fi
  
  return 0 # Not throttled
}

bg_update_throttle_timestamp() {
  local notification_type="$1"
  local throttle_dir
  
  # Set up directories for timestamp files
  XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
  throttle_dir="${XDG_STATE_HOME}/battery-guardian/notifications"
  
  # Create directory if it doesn't exist
  mkdir -p "$throttle_dir" 2>/dev/null
  
  local timestamp_file="$throttle_dir/${notification_type}_timestamp"
  
  # Update timestamp
  date +%s >"$timestamp_file" 2>/dev/null
}

# Ensure BG_NOTIFICATION_FILE is defined
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
BG_NOTIFICATION_FILE="${XDG_RUNTIME_DIR}/battery-guardian/last_notification.txt"
mkdir -p "$(dirname "$BG_NOTIFICATION_FILE")" 2>/dev/null

# ---- Notification Functions ----
bg_send_notification() {
  local title="$1"
  local message="$2"
  local urgency="${3:-normal}"
  local notification_type="${4:-general}"
  
  # Check if notifications are disabled
  if [[ "${BG_ENABLE_NOTIFICATIONS:-1}" == "0" ]]; then
    bg_debug "Notifications are disabled. Skipping: '$title' - '$message'"
    return 0
  fi
  
  # Check for notification cooldown if type is specified
  if [[ -n "$notification_type" ]]; then
    if ! bg_should_throttle "$notification_type"; then
      bg_debug "Notification throttled: '$title' ($notification_type) - within cooldown period"
      return 0
    fi
    # Update timestamp for this notification type
    bg_update_throttle_timestamp "$notification_type"
  fi

  if ! bg_check_command_exists "notify-send"; then
    bg_error "notify-send not found. Cannot send notification: '$title' - '$message'"
    return 1
  fi

  notify-send -u "$urgency" "$title" "$message" 2>/dev/null ||
    bg_error "Failed to send notification: '$title' - '$message'"
}

bg_should_send_notification() {
  local battery_percent=$1
  local ac_status=$2
  local notification_type=""

  # Determine notification type based on battery percentage
  if [ "$battery_percent" -le "$bg_CRITICAL_THRESHOLD" ]; then
    notification_type="critical"
  elif [ "$battery_percent" -le "$bg_LOW_THRESHOLD" ]; then
    notification_type="low"
  elif [ "$battery_percent" -ge "$bg_FULL_BATTERY_THRESHOLD" ] && [ "$ac_status" == "Charging" ]; then
    notification_type="full"
  else
    return 1 # No notification needed
  fi

  # Check if we've sent this notification recently
  if [ -f "$BG_NOTIFICATION_FILE" ]; then
    local last_notification
    last_notification=$(cat "$BG_NOTIFICATION_FILE")
    if [[ $? -ne 0 ]]; then
      bg_warn "Failed to read last notification info."
      return 0 # Assume we should send notification
    fi

    local last_type=${last_notification%:*}
    local last_time=${last_notification#*:}
    local current_time
    current_time=$(date +%s)
    if [[ $? -ne 0 ]]; then
      bg_warn "Failed to get current time."
      return 0 # Assume we should send notification
    fi

    # If same notification type was sent within cooldown period, skip it
    if [ "$notification_type" == "$last_type" ] &&
      ((current_time - last_time < bg_NOTIFICATION_COOLDOWN)); then
      return 1 # Skip notification
    fi
  fi

  return 0 # Send notification
}

bg_send_battery_notification() {
  local battery_percent=$1
  local ac_status=$2
  local notification_type=""

  if [ "$battery_percent" -le "$bg_CRITICAL_THRESHOLD" ]; then
    notification_type="critical"
    bg_info "Battery is critically low at $battery_percent%. Sending critical notification."
    bg_send_notification "Critical Battery" "Battery is at $battery_percent%. Please plug in the charger." "critical" "battery_critical"
  elif [ "$battery_percent" -le "$bg_LOW_THRESHOLD" ]; then
    notification_type="low"
    bg_info "Battery is low at $battery_percent%. Sending low notification."
    bg_send_notification "Low Battery" "Battery is at $battery_percent%. Consider plugging in the charger." "normal" "battery_low"
  elif [ "$battery_percent" -ge "$bg_FULL_BATTERY_THRESHOLD" ] && [ "$ac_status" == "Charging" ]; then
    notification_type="full"
    bg_info "Battery is fully charged at $battery_percent%. Sending notification."
    bg_send_notification "Battery Full" "Battery is fully charged ($battery_percent%)." "normal" "battery_full"
  else
    return 0 # No notification needed
  fi

  # Save last notification type and time to avoid duplicate notifications
  echo "${notification_type}:$(date +%s)" >"$BG_NOTIFICATION_FILE"
}
