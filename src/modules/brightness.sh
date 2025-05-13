#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Brightness control functions
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

# Load brightness config variables if they don't exist
if [[ -z "${bg_BRIGHTNESS_CONTROL_ENABLED:-}" ]]; then
  # Try loading from defaults first
  # Check if BG_PARENT_DIR is already set, don't try to modify it
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
    bg_BRIGHTNESS_CONTROL_ENABLED=true
    bg_BRIGHTNESS_MAX=100
    bg_BRIGHTNESS_HIGH=85
    bg_BRIGHTNESS_MEDIUM=60
    bg_BRIGHTNESS_LOW=35
    bg_BRIGHTNESS_CRITICAL=15
  fi
fi

# ---- Brightness Control Functions ----
bg_get_brightness() {
  local brightness=0
  
  # Try using brightnessctl first
  if bg_check_command_exists brightnessctl; then
    brightness=$(brightnessctl -m -p get | tr -d '%')
    return 0
  fi
  
  # Try light command next
  if bg_check_command_exists light; then
    brightness=$(light -G | tr -d '.')
    return 0
  fi
  
  # Try xbacklight next
  if bg_check_command_exists xbacklight; then
    brightness=$(xbacklight -get | awk '{print int($1)}')
    return 0
  fi
  
  # If all else fails, try sysfs
  if [[ -n "${bg_BACKLIGHT_PATH:-}" ]]; then
    local current_brightness
    local max_brightness
    
    current_brightness=$(cat "$bg_BACKLIGHT_PATH/brightness")
    max_brightness=$(cat "$bg_BACKLIGHT_PATH/max_brightness")
    
    brightness=$(bg_calculate_brightness_percentage "$current_brightness" "$max_brightness")
  else
    # Try to find a backlight device
    local backlight_dir="/sys/class/backlight"
    if [[ -d "$backlight_dir" ]]; then
      # Get the first backlight device
      local device
      device=$(find "$backlight_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
      
      if [[ -n "$device" ]]; then
        bg_BACKLIGHT_PATH="$device"
        current_brightness=$(cat "$device/brightness")
        max_brightness=$(cat "$device/max_brightness")
        
        brightness=$(bg_calculate_brightness_percentage "$current_brightness" "$max_brightness")
      fi
    fi
  fi
  
  echo "$brightness"
}

# Calculate brightness percentage
bg_calculate_brightness_percentage() {
  local current="$1"
  local max="$2"
  
  echo $(( (current * 100) / max ))
}

# Legacy function name for compatibility
bg_get_current_brightness() {
  local brightness=100
  local success=false

  # Try using brightnessctl if available
  if bg_check_command_exists "brightnessctl"; then
    local brightnessctl_output
    brightnessctl_output=$(brightnessctl g 2>/dev/null)
    if [[ $? -eq 0 && -n "$brightnessctl_output" ]]; then
      # Create a fallback in case we can't determine max brightness properly
      local max_brightness
      max_brightness=$(brightnessctl m 2>/dev/null)
      if [[ $? -eq 0 && -n "$max_brightness" && "$max_brightness" =~ ^[0-9]+$ && "$max_brightness" -gt 0 ]]; then
        brightness=$(((brightnessctl_output * 100) / max_brightness))
      else
        # Fallback to assuming standard 0-255 range
        brightness=$(echo "$brightnessctl_output" | awk '{print int($1 / 255 * 100)}')
      fi

      if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
        success=true
        bg_info "Got brightness $brightness% via brightnessctl"
        echo "$brightness"
        return
      fi
    fi
    bg_warn "Failed to get valid brightness from brightnessctl."
  fi

  # Try using light if available
  if bg_check_command_exists "light"; then
    local light_output
    light_output=$(light -G 2>/dev/null)
    if [[ $? -eq 0 && -n "$light_output" ]]; then
      brightness=$(echo "$light_output" | awk '{print int($1)}')
      if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
        success=true
        bg_info "Got brightness $brightness% via light"
        echo "$brightness"
        return
      fi
    fi
    bg_warn "Failed to get valid brightness from light."
  fi

  # Try using xbacklight if available (X11 only)
  if bg_check_command_exists "xbacklight"; then
    local xbacklight_output
    xbacklight_output=$(xbacklight -get 2>/dev/null)
    if [[ $? -eq 0 && -n "$xbacklight_output" ]]; then
      brightness=$(echo "$xbacklight_output" | awk '{print int($1)}')
      if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
        success=true
        bg_info "Got brightness $brightness% via xbacklight"
        echo "$brightness"
        return
      fi
    fi
    bg_warn "Failed to get valid brightness from xbacklight."
  fi

  # Try direct sysfs method for Linux - with added error handling
  for backlight_dir in /sys/class/backlight/*; do
    if [[ -d "$backlight_dir" && -f "$backlight_dir/brightness" && -f "$backlight_dir/max_brightness" ]]; then
      local current max
      current=$(cat "$backlight_dir/brightness" 2>/dev/null)
      max=$(cat "$backlight_dir/max_brightness" 2>/dev/null)

      if [[ $? -eq 0 && -n "$current" && -n "$max" && "$current" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
        # Using bc for more precise calculation if available
        if bg_check_command_exists "bc"; then
          brightness=$(echo "scale=0; ($current * 100) / $max" | bc 2>/dev/null)
        else
          # Fallback to simpler but less precise calculation
          brightness=$(((current * 100) / max))
        fi

        if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
          success=true
          bg_info "Got brightness $brightness% via sysfs ($backlight_dir)"
          echo "$brightness"
          return
        fi
      fi
    fi
  done

  if ! $success; then
    bg_warn "No supported brightness control method found. Using default: $brightness%"
  fi

  echo "$brightness" # Return default value
}

# Set brightness to a specific percentage
bg_set_brightness() {
  local target_brightness="$1"
  
  # Validate input
  if [[ ! "$target_brightness" =~ ^[0-9]+$ ]] || [ "$target_brightness" -lt 0 ] || [ "$target_brightness" -gt 100 ]; then
    bg_error "Invalid brightness value: $target_brightness (should be 0-100)"
    return 1
  fi
  
  bg_debug "Setting brightness to $target_brightness%"
  
  # Try using brightnessctl first
  if bg_check_command_exists brightnessctl; then
    brightnessctl s "$target_brightness%" -q
    return $?
  fi
  
  # Try light command next
  if bg_check_command_exists light; then
    light -S "$target_brightness"
    return $?
  fi
  
  # Try xbacklight next
  if bg_check_command_exists xbacklight; then
    xbacklight -set "$target_brightness"
    return $?
  fi
  
  # If all else fails, try sysfs if available
  if [[ -n "${bg_BACKLIGHT_PATH:-}" ]]; then
    if [[ -f "$bg_BACKLIGHT_PATH/brightness" && -f "$bg_BACKLIGHT_PATH/max_brightness" ]]; then
      local max_brightness
      max_brightness=$(cat "$bg_BACKLIGHT_PATH/max_brightness")
      
      # Calculate raw brightness value
      local raw_brightness
      raw_brightness=$(( (target_brightness * max_brightness) / 100 ))
      
      # Check if we have write permission
      if [[ -w "$bg_BACKLIGHT_PATH/brightness" ]]; then
        echo "$raw_brightness" > "$bg_BACKLIGHT_PATH/brightness"
        return $?
      else
        bg_error "No write permission for $bg_BACKLIGHT_PATH/brightness"
        return 1
      fi
    fi
  fi
  
  bg_error "No supported brightness control method available"
  return 1
}

# Auto-adjust brightness based on power source
bg_auto_brightness() {
  # Check if auto-brightness is enabled
  if [[ "${bg_AUTO_BRIGHTNESS_ENABLED:-0}" -ne 1 ]]; then
    bg_debug "Auto brightness adjustment is disabled"
    return 0
  fi
  
  # Get AC status
  local ac_status
  ac_status=$(bg_check_ac_status)
  
  # Get current brightness
  local current_brightness
  current_brightness=$(bg_get_brightness)
  
  # Set target brightness based on power source
  local target_brightness
  if [[ "$ac_status" == "Charging" ]]; then
    target_brightness="${bg_AUTO_BRIGHTNESS_AC:-100}"
    bg_debug "On AC power, setting brightness to $target_brightness%"
  else
    target_brightness="${bg_AUTO_BRIGHTNESS_BATTERY:-50}"
    bg_debug "On battery, setting brightness to $target_brightness%"
  fi
  
  # Only change brightness if it's significantly different from current
  if [[ $((current_brightness - target_brightness)) -ge 5 ]] || [[ $((target_brightness - current_brightness)) -ge 5 ]]; then
    bg_set_brightness "$target_brightness"
  else
    bg_debug "Current brightness ($current_brightness%) is close to target ($target_brightness%), skipping adjustment"
  fi
  
  return 0
}

bg_adjust_brightness_for_battery() {
  local battery_percent=$1
  local ac_status=$2
  local target_brightness

  # Skip brightness adjustment if feature is disabled
  if [ "$bg_BRIGHTNESS_CONTROL_ENABLED" != "true" ]; then
    return
  fi

  # When charging, use maximum brightness or high brightness depending on battery level
  if [ "$ac_status" == "Charging" ]; then
    # When charging but battery not yet almost full, use a slightly reduced brightness
    if [ "$battery_percent" -lt "$bg_BATTERY_ALMOST_FULL_THRESHOLD" ]; then
      target_brightness=$bg_BRIGHTNESS_VERY_HIGH
    else
      # When charging and battery almost full or full, use maximum brightness
      target_brightness=$bg_BRIGHTNESS_MAX
    fi
  else
    # When on battery, adjust brightness based on the battery percentage
    if [ "$battery_percent" -le "$bg_CRITICAL_THRESHOLD" ]; then
      target_brightness=$bg_BRIGHTNESS_CRITICAL
    elif [ "$battery_percent" -le "$bg_BATTERY_LOW_THRESHOLD" ]; then
      target_brightness=$bg_BRIGHTNESS_VERY_LOW
    elif [ "$battery_percent" -le "$bg_BATTERY_MEDIUM_LOW_THRESHOLD" ]; then
      target_brightness=$bg_BRIGHTNESS_LOW
    elif [ "$battery_percent" -le "$bg_BATTERY_MEDIUM_THRESHOLD" ]; then
      target_brightness=$bg_BRIGHTNESS_MEDIUM_LOW
    elif [ "$battery_percent" -le "$bg_BATTERY_MEDIUM_HIGH_THRESHOLD" ]; then
      target_brightness=$bg_BRIGHTNESS_MEDIUM
    elif [ "$battery_percent" -le "$bg_BATTERY_HIGH_THRESHOLD" ]; then
      target_brightness=$bg_BRIGHTNESS_MEDIUM_HIGH
    elif [ "$battery_percent" -le "$bg_BATTERY_VERY_HIGH_THRESHOLD" ]; then
      target_brightness=$bg_BRIGHTNESS_HIGH
    else
      # Above very high threshold
      target_brightness=$bg_BRIGHTNESS_VERY_HIGH
    fi
  fi

  # Get current brightness
  local current_brightness
  current_brightness=$(bg_get_current_brightness)

  # Only change brightness if it differs significantly from target
  if [ $((current_brightness - target_brightness)) -ge 5 ] || [ $((target_brightness - current_brightness)) -ge 5 ]; then
    bg_info "Adjusting brightness from $current_brightness% to $target_brightness% based on battery level ($battery_percent%)"
    bg_set_brightness "$target_brightness"

    # Only notify if the change is significant
    if [ $((current_brightness - target_brightness)) -ge 15 ] || [ $((target_brightness - current_brightness)) -ge 15 ]; then
      bg_send_notification "Battery Saver" "Screen brightness adjusted to $target_brightness% (Battery: $battery_percent%)" "low"
    fi
  fi
}
