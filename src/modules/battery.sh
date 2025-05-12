#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Battery functions module
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

# ---- Battery Status Functions ----
bg_check_battery() {
  local percent=0

  # First try the more specific check using our previously found battery
  if [[ -n "$bg_BATTERY_PATH" && -f "$bg_BATTERY_PATH/capacity" ]]; then
    percent=$(cat "$bg_BATTERY_PATH/capacity" 2>/dev/null)
    if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
      echo "$percent"
      return
    fi
    # If reading failed, fall through to other methods
    bg_warn "Failed to read from cached battery path: $bg_BATTERY_PATH"
  fi

  # Look for any battery in /sys/class/power_supply with systematic error handling
  for bat in /sys/class/power_supply/BAT*; do
    if [[ -f "$bat/capacity" ]]; then
      percent=$(cat "$bat/capacity" 2>/dev/null)
      if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
        # Cache this successful path for future reads
        bg_BATTERY_PATH="$bat"
        bg_info "Found working battery at $bg_BATTERY_PATH"
        echo "$percent"
        return
      fi
    fi
  done

  # Try alternate battery naming schemes
  for alt_bat in /sys/class/power_supply/*; do
    if [[ -d "$alt_bat" && -f "$alt_bat/capacity" && -f "$alt_bat/type" ]]; then
      local type
      type=$(cat "$alt_bat/type" 2>/dev/null)
      if [[ "$type" == "Battery" ]]; then
        percent=$(cat "$alt_bat/capacity" 2>/dev/null)
        if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
          # Cache this successful path for future reads
          bg_BATTERY_PATH="$alt_bat"
          bg_info "Found working battery at $bg_BATTERY_PATH"
          echo "$percent"
          return
        fi
      fi
    fi
  done

  # Fallback to acpi command if available
  if bg_check_command_exists "acpi"; then
    percent=$(acpi -b 2>/dev/null | grep -P -o '[0-9]+(?=%)' | head -n1)
    if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
      echo "$percent"
      return
    fi
    bg_warn "Failed to get valid battery percentage from acpi."
  fi

  # If we reach this point, we couldn't get a valid reading
  bg_error "Failed to get valid battery percentage through any method. Using safe default."
  echo "50" # Return a safe default value
}

bg_check_ac_status() {
  local status="Discharging"

  # Use cached path if available
  if [[ -n "$bg_AC_PATH" && -f "$bg_AC_PATH/online" ]]; then
    local online
    online=$(cat "$bg_AC_PATH/online" 2>/dev/null)
    if [[ $? -eq 0 && -n "$online" ]]; then
      [[ "$online" == "1" ]] && status="Charging" || status="Discharging"
      echo "$status"
      return
    fi
    # If reading failed, fall through to other methods
    bg_warn "Failed to read AC status from cached path: $bg_AC_PATH"
  fi

  # Try common AC adapter paths
  for adapter in "/sys/class/power_supply/AC" "/sys/class/power_supply/ACAD" "/sys/class/power_supply/ADP1"; do
    if [[ -f "$adapter/online" ]]; then
      local online
      online=$(cat "$adapter/online" 2>/dev/null)
      if [[ $? -eq 0 && -n "$online" ]]; then
        # Cache this successful path for future reads
        bg_AC_PATH="$adapter"
        bg_info "Found working AC adapter at $bg_AC_PATH"
        [[ "$online" == "1" ]] && status="Charging" || status="Discharging"
        echo "$status"
        return
      fi
    fi
  done

  # Try to find AC adapter by looking for type=Mains
  for adapter in /sys/class/power_supply/*; do
    if [[ -f "$adapter/type" && -f "$adapter/online" ]]; then
      local type
      type=$(cat "$adapter/type" 2>/dev/null)
      if [[ "$type" == "Mains" ]]; then
        local online
        online=$(cat "$adapter/online" 2>/dev/null)
        if [[ $? -eq 0 && -n "$online" ]]; then
          # Cache this successful path for future reads
          bg_AC_PATH="$adapter"
          bg_info "Found working AC adapter at $bg_AC_PATH"
          [[ "$online" == "1" ]] && status="Charging" || status="Discharging"
          echo "$status"
          return
        fi
      fi
    fi
  done

  # Try checking battery status directly
  if [[ -n "$bg_BATTERY_PATH" && -f "$bg_BATTERY_PATH/status" ]]; then
    local bat_status
    bat_status=$(cat "$bg_BATTERY_PATH/status" 2>/dev/null)
    if [[ $? -eq 0 && -n "$bat_status" ]]; then
      case "$bat_status" in
      "Charging" | "Full") status="Charging" ;;
      "Discharging" | "Not charging") status="Discharging" ;;
      *) bg_warn "Unknown battery status: $bat_status" ;;
      esac
      echo "$status"
      return
    fi
  fi

  # Fallback to acpi command
  if bg_check_command_exists "acpi"; then
    if acpi -a 2>/dev/null | grep -q "on-line"; then
      status="Charging"
    elif acpi -a 2>/dev/null | grep -q "off-line"; then
      status="Discharging"
    else
      bg_warn "Could not determine AC status from acpi output"
    fi
    echo "$status"
    return
  fi

  bg_warn "Failed to determine AC status through any method. Using default: $status"
  echo "$status" # Return default value
}

# ---- Battery Detection Function ----
bg_check_battery_exists() {
  bg_info "Checking for battery presence..."

  # Check for battery in /sys/class/power_supply
  for bat in /sys/class/power_supply/BAT*; do
    if [[ -d "$bat" ]]; then
      bg_info "Battery found at $bat"
      return 0
    fi
  done

  # Try alternate battery paths (some systems use different naming)
  for alt_bat in /sys/class/power_supply/*; do
    if [[ -d "$alt_bat" && -f "$alt_bat/capacity" && -f "$alt_bat/type" ]]; then
      local type=$(cat "$alt_bat/type" 2>/dev/null)
      if [[ "$type" == "Battery" ]]; then
        bg_info "Battery found at $alt_bat"
        return 0
      fi
    fi
  done

  # Try using acpi as fallback
  if bg_check_command_exists "acpi"; then
    if acpi -b 2>/dev/null | grep -q "Battery"; then
      bg_info "Battery detected via acpi command"
      return 0
    fi
  fi

  bg_info "No battery detected on this system"
  return 1
}
