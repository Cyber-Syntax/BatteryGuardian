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

# ---- Notification Functions ----
bg_send_notification() {
  local title="$1"
  local message="$2"
  local urgency="${3:-normal}"

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
    bg_send_notification "Battery Warning" "Battery is at $battery_percent%. Please plug in the charger." "critical"
  elif [ "$battery_percent" -le "$bg_LOW_THRESHOLD" ]; then
    notification_type="low"
    bg_info "Battery is low at $battery_percent%. Sending low notification."
    bg_send_notification "Battery Warning" "Battery is at $battery_percent%. Consider plugging in the charger." "normal"
  elif [ "$battery_percent" -ge "$bg_FULL_BATTERY_THRESHOLD" ] && [ "$ac_status" == "Charging" ]; then
    notification_type="full"
    bg_info "Battery is fully charged at $battery_percent%. Sending notification."
    bg_send_notification "Battery Info" "Battery is fully charged ($battery_percent%)." "normal"
  else
    return 0 # No notification needed
  fi

  # Save last notification type and time to avoid duplicate notifications
  echo "${notification_type}:$(date +%s)" >"$BG_NOTIFICATION_FILE"
}
