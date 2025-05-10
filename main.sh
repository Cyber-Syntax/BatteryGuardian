#!/bin/bash
### Battery Warning Script

# Configuration
LOW_THRESHOLD=20
CRITICAL_THRESHOLD=10
FULL_BATTERY_THRESHOLD=90
BATTERY_ALMOST_FULL_THRESHOLD=85 # Added threshold for almost full
NOTIFICATION_COOLDOWN=300        # seconds between identical notifications

# Brightness Configuration
BRIGHTNESS_CONTROL_ENABLED=true
BRIGHTNESS_MAX=100        # Maximum brightness (for AC power)
BRIGHTNESS_VERY_HIGH=95   # For battery >85%
BRIGHTNESS_HIGH=85        # For battery >70%
BRIGHTNESS_MEDIUM_HIGH=70 # For battery >60%
BRIGHTNESS_MEDIUM=60      # For battery >50%
BRIGHTNESS_MEDIUM_LOW=45  # For battery >30%
BRIGHTNESS_LOW=35         # For battery >20%
BRIGHTNESS_VERY_LOW=25    # For battery >10%
BRIGHTNESS_CRITICAL=15    # For critical battery <=10%

# Battery thresholds for brightness changes
BATTERY_VERY_HIGH_THRESHOLD=85 # Almost full battery
BATTERY_HIGH_THRESHOLD=70
BATTERY_MEDIUM_HIGH_THRESHOLD=60
BATTERY_MEDIUM_THRESHOLD=50
BATTERY_MEDIUM_LOW_THRESHOLD=30
BATTERY_LOW_THRESHOLD=20
# Critical threshold is already defined above

# Cache variables for efficient access
BATTERY_PATH=""  # Will be populated when a working battery path is found
AC_PATH="" # Will be populated when a working AC path is found

# log file path
log_file="$HOME/.config/hypr/logs/battery.log"

# Runtime file for storing state between executions
state_dir="/tmp/hypr_battery_script"
mkdir -p "$state_dir" 2>/dev/null || {
    # If can't create state directory, use fallback
    state_dir="/tmp"
    log "WARNING: Could not create state directory, using fallback"
}

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$log_file")" || {
    log_file="/tmp/hypr-battery.log"
    echo "WARNING: Could not create log directory, using fallback log file: $log_file"
}

# Create lock file to prevent multiple instances
LOCK_FILE="/tmp/battery_monitor.lock"

# Check if the script is already running
check_lock() {
  if [ -f "$LOCK_FILE" ]; then
    # Check if the process is still running
    OLDPID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ "$OLDPID" =~ ^[0-9]+$ ]] && kill -0 "$OLDPID" 2>/dev/null; then
      log "Script is already running with PID $OLDPID. Exiting."
      exit 0
    else
      log "Found stale lock file. Previous process seems to have died unexpectedly."
    fi
  fi
  # Create lockfile
  echo $$ > "$LOCK_FILE" || {
    log "ERROR: Failed to create lock file. Continuing without lock."
  }
}

# Cleanup function
cleanup() {
  log "Battery monitoring script terminated."
  rm -f "$LOCK_FILE"
  exit 0
}

# Set up trap for clean exit
trap cleanup SIGINT SIGTERM EXIT

# Check lock before proceeding
check_lock

# logging function
log() {
  local datetime
  datetime=$(date +'%Y-%m-%d %H:%M:%S')
  if [[ $? -ne 0 ]]; then
    # Fallback if date command fails
    datetime="[TIME ERROR]"
  fi
  echo "$datetime: $1" >>"$log_file"
}

# Function to check if a command exists
check_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to validate configuration variables
validate_config() {
  local has_errors=false

  # Validate thresholds
  if [[ ! "$LOW_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$LOW_THRESHOLD" -lt 5 ] || [ "$LOW_THRESHOLD" -gt 50 ]; then
    log "ERROR: Invalid LOW_THRESHOLD value: $LOW_THRESHOLD. Setting to default 20%."
    LOW_THRESHOLD=20
    has_errors=true
  fi

  if [[ ! "$CRITICAL_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$CRITICAL_THRESHOLD" -lt 3 ] || [ "$CRITICAL_THRESHOLD" -gt "$LOW_THRESHOLD" ]; then
    log "ERROR: Invalid CRITICAL_THRESHOLD value: $CRITICAL_THRESHOLD. Setting to default 10%."
    CRITICAL_THRESHOLD=10
    has_errors=true
  fi

  if [[ ! "$FULL_BATTERY_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$FULL_BATTERY_THRESHOLD" -lt 80 ] || [ "$FULL_BATTERY_THRESHOLD" -gt 100 ]; then
    log "ERROR: Invalid FULL_BATTERY_THRESHOLD value: $FULL_BATTERY_THRESHOLD. Setting to default 90%."
    FULL_BATTERY_THRESHOLD=90
    has_errors=true
  fi

  # Validate brightness values
  if [ "$BRIGHTNESS_CONTROL_ENABLED" != "true" ] && [ "$BRIGHTNESS_CONTROL_ENABLED" != "false" ]; then
    log "ERROR: Invalid BRIGHTNESS_CONTROL_ENABLED value. Setting to default (true)."
    BRIGHTNESS_CONTROL_ENABLED=true
    has_errors=true
  fi

  # Validate brightness levels (ensure they're all valid integers)
  local brightness_vars=(BRIGHTNESS_MAX BRIGHTNESS_VERY_HIGH BRIGHTNESS_HIGH BRIGHTNESS_MEDIUM_HIGH
                        BRIGHTNESS_MEDIUM BRIGHTNESS_MEDIUM_LOW BRIGHTNESS_LOW BRIGHTNESS_VERY_LOW BRIGHTNESS_CRITICAL)

  for var_name in "${brightness_vars[@]}"; do
    local value=${!var_name}
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 5 ] || [ "$value" -gt 100 ]; then
      log "ERROR: Invalid $var_name value: $value. Setting to safe default."
      # Set default based on variable name
      case "$var_name" in
        BRIGHTNESS_MAX) eval "$var_name=100" ;;
        BRIGHTNESS_VERY_HIGH) eval "$var_name=95" ;;
        BRIGHTNESS_HIGH) eval "$var_name=85" ;;
        BRIGHTNESS_MEDIUM_HIGH) eval "$var_name=70" ;;
        BRIGHTNESS_MEDIUM) eval "$var_name=60" ;;
        BRIGHTNESS_MEDIUM_LOW) eval "$var_name=45" ;;
        BRIGHTNESS_LOW) eval "$var_name=35" ;;
        BRIGHTNESS_VERY_LOW) eval "$var_name=25" ;;
        BRIGHTNESS_CRITICAL) eval "$var_name=15" ;;
      esac
      has_errors=true
    fi
  done

  # Ensure brightness thresholds are in descending order
  if [ "$BRIGHTNESS_MAX" -lt "$BRIGHTNESS_VERY_HIGH" ] ||
     [ "$BRIGHTNESS_VERY_HIGH" -lt "$BRIGHTNESS_HIGH" ] ||
     [ "$BRIGHTNESS_HIGH" -lt "$BRIGHTNESS_MEDIUM_HIGH" ] ||
     [ "$BRIGHTNESS_MEDIUM_HIGH" -lt "$BRIGHTNESS_MEDIUM" ] ||
     [ "$BRIGHTNESS_MEDIUM" -lt "$BRIGHTNESS_MEDIUM_LOW" ] ||
     [ "$BRIGHTNESS_MEDIUM_LOW" -lt "$BRIGHTNESS_LOW" ] ||
     [ "$BRIGHTNESS_LOW" -lt "$BRIGHTNESS_VERY_LOW" ] ||
     [ "$BRIGHTNESS_VERY_LOW" -lt "$BRIGHTNESS_CRITICAL" ]; then
    log "ERROR: Brightness values not in descending order. Some values will be adjusted."

    # Ensure a sane minimum
    [ "$BRIGHTNESS_CRITICAL" -lt 10 ] && BRIGHTNESS_CRITICAL=10

    # Fix ascending order if needed
    [ "$BRIGHTNESS_VERY_LOW" -le "$BRIGHTNESS_CRITICAL" ] && BRIGHTNESS_VERY_LOW=$(( BRIGHTNESS_CRITICAL + 5 ))
    [ "$BRIGHTNESS_LOW" -le "$BRIGHTNESS_VERY_LOW" ] && BRIGHTNESS_LOW=$(( BRIGHTNESS_VERY_LOW + 5 ))
    [ "$BRIGHTNESS_MEDIUM_LOW" -le "$BRIGHTNESS_LOW" ] && BRIGHTNESS_MEDIUM_LOW=$(( BRIGHTNESS_LOW + 5 ))
    [ "$BRIGHTNESS_MEDIUM" -le "$BRIGHTNESS_MEDIUM_LOW" ] && BRIGHTNESS_MEDIUM=$(( BRIGHTNESS_MEDIUM_LOW + 5 ))
    [ "$BRIGHTNESS_MEDIUM_HIGH" -le "$BRIGHTNESS_MEDIUM" ] && BRIGHTNESS_MEDIUM_HIGH=$(( BRIGHTNESS_MEDIUM + 5 ))
    [ "$BRIGHTNESS_HIGH" -le "$BRIGHTNESS_MEDIUM_HIGH" ] && BRIGHTNESS_HIGH=$(( BRIGHTNESS_MEDIUM_HIGH + 5 ))
    [ "$BRIGHTNESS_VERY_HIGH" -le "$BRIGHTNESS_HIGH" ] && BRIGHTNESS_VERY_HIGH=$(( BRIGHTNESS_HIGH + 5 ))
    [ "$BRIGHTNESS_MAX" -le "$BRIGHTNESS_VERY_HIGH" ] && BRIGHTNESS_MAX=$(( BRIGHTNESS_VERY_HIGH + 5 ))

    # Cap at 100%
    [ "$BRIGHTNESS_MAX" -gt 100 ] && BRIGHTNESS_MAX=100
    has_errors=true
  fi

  # Print all configuration values if there were errors
  if [ "$has_errors" = true ]; then
    log "Fixed configuration values:"
    log "LOW_THRESHOLD=$LOW_THRESHOLD, CRITICAL_THRESHOLD=$CRITICAL_THRESHOLD, FULL_BATTERY_THRESHOLD=$FULL_BATTERY_THRESHOLD"
    log "BRIGHTNESS_MAX=$BRIGHTNESS_MAX, BRIGHTNESS_VERY_HIGH=$BRIGHTNESS_VERY_HIGH, BRIGHTNESS_HIGH=$BRIGHTNESS_HIGH"
    log "BRIGHTNESS_MEDIUM_HIGH=$BRIGHTNESS_MEDIUM_HIGH, BRIGHTNESS_MEDIUM=$BRIGHTNESS_MEDIUM"
    log "BRIGHTNESS_MEDIUM_LOW=$BRIGHTNESS_MEDIUM_LOW, BRIGHTNESS_LOW=$BRIGHTNESS_LOW"
    log "BRIGHTNESS_VERY_LOW=$BRIGHTNESS_VERY_LOW, BRIGHTNESS_CRITICAL=$BRIGHTNESS_CRITICAL"
  fi
}

# Function to check battery percentage
check_battery() {
  local percent=0

  # First try the more specific check using our previously found battery
  if [[ -n "$BATTERY_PATH" && -f "$BATTERY_PATH/capacity" ]]; then
    percent=$(cat "$BATTERY_PATH/capacity" 2>/dev/null)
    if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
      echo "$percent"
      return
    fi
    # If reading failed, fall through to other methods
    log "WARNING: Failed to read from cached battery path: $BATTERY_PATH"
  fi

  # Look for any battery in /sys/class/power_supply with systematic error handling
  for bat in /sys/class/power_supply/BAT*; do
    if [[ -f "$bat/capacity" ]]; then
      percent=$(cat "$bat/capacity" 2>/dev/null)
      if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
        # Cache this successful path for future reads
        BATTERY_PATH="$bat"
        log "Found working battery at $BATTERY_PATH"
        echo "$percent"
        return
      fi
    fi
  done

  # Try alternate battery naming schemes
  for alt_bat in /sys/class/power_supply/*; do
    if [[ -d "$alt_bat" && -f "$alt_bat/capacity" && -f "$alt_bat/type" ]]; then
      local type=$(cat "$alt_bat/type" 2>/dev/null)
      if [[ "$type" == "Battery" ]]; then
        percent=$(cat "$alt_bat/capacity" 2>/dev/null)
        if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
          # Cache this successful path for future reads
          BATTERY_PATH="$alt_bat"
          log "Found working battery at $BATTERY_PATH"
          echo "$percent"
          return
        fi
      fi
    fi
  done

  # Fallback to acpi command if available
  if check_command_exists "acpi"; then
    percent=$(acpi -b 2>/dev/null | grep -P -o '[0-9]+(?=%)' | head -n1)
    if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
      echo "$percent"
      return
    fi
    log "WARNING: Failed to get valid battery percentage from acpi."
  fi

  # If we reach this point, we couldn't get a valid reading
  log "ERROR: Failed to get valid battery percentage through any method. Using safe default."
  echo "50"  # Return a safe default value
}

# Function to check AC status
check_ac_status() {
  local status="Discharging"

  # Use cached path if available
  if [[ -n "$AC_PATH" && -f "$AC_PATH/online" ]]; then
    local online
    online=$(cat "$AC_PATH/online" 2>/dev/null)
    if [[ $? -eq 0 && -n "$online" ]]; then
      [[ "$online" == "1" ]] && status="Charging" || status="Discharging"
      echo "$status"
      return
    fi
    # If reading failed, fall through to other methods
    log "WARNING: Failed to read AC status from cached path: $AC_PATH"
  fi

  # Try common AC adapter paths
  for adapter in "/sys/class/power_supply/AC" "/sys/class/power_supply/ACAD" "/sys/class/power_supply/ADP1"; do
    if [[ -f "$adapter/online" ]]; then
      local online
      online=$(cat "$adapter/online" 2>/dev/null)
      if [[ $? -eq 0 && -n "$online" ]]; then
        # Cache this successful path for future reads
        AC_PATH="$adapter"
        log "Found working AC adapter at $AC_PATH"
        [[ "$online" == "1" ]] && status="Charging" || status="Discharging"
        echo "$status"
        return
      fi
    fi
  done

  # Try to find AC adapter by looking for type=Mains
  for adapter in /sys/class/power_supply/*; do
    if [[ -f "$adapter/type" && -f "$adapter/online" ]]; then
      local type=$(cat "$adapter/type" 2>/dev/null)
      if [[ "$type" == "Mains" ]]; then
        local online=$(cat "$adapter/online" 2>/dev/null)
        if [[ $? -eq 0 && -n "$online" ]]; then
          # Cache this successful path for future reads
          AC_PATH="$adapter"
          log "Found working AC adapter at $AC_PATH"
          [[ "$online" == "1" ]] && status="Charging" || status="Discharging"
          echo "$status"
          return
        fi
      fi
    fi
  done

  # Try checking battery status directly
  if [[ -n "$BATTERY_PATH" && -f "$BATTERY_PATH/status" ]]; then
    local bat_status=$(cat "$BATTERY_PATH/status" 2>/dev/null)
    if [[ $? -eq 0 && -n "$bat_status" ]]; then
      case "$bat_status" in
        "Charging"|"Full") status="Charging" ;;
        "Discharging"|"Not charging") status="Discharging" ;;
        *) log "WARNING: Unknown battery status: $bat_status" ;;
      esac
      echo "$status"
      return
    fi
  fi

  # Fallback to acpi command
  if check_command_exists "acpi"; then
    if acpi -a 2>/dev/null | grep -q "on-line"; then
      status="Charging"
    elif acpi -a 2>/dev/null | grep -q "off-line"; then
      status="Discharging"
    else
      log "WARNING: Could not determine AC status from acpi output"
    fi
    echo "$status"
    return
  fi

  log "WARNING: Failed to determine AC status through any method. Using default: $status"
  echo "$status" # Return default value
}

# Function to get current screen brightness with maximum error handling
get_current_brightness() {
  local brightness=100
  local success=false

  # Try using brightnessctl if available
  if check_command_exists "brightnessctl"; then
    local brightnessctl_output
    brightnessctl_output=$(brightnessctl g 2>/dev/null)
    if [[ $? -eq 0 && -n "$brightnessctl_output" ]]; then
      brightness=$(echo "$brightnessctl_output" | awk '{print int($1 / 255 * 100)}')
      if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
        success=true
        log "Got brightness $brightness% via brightnessctl"
        echo "$brightness"
        return
      fi
    fi
    log "WARNING: Failed to get valid brightness from brightnessctl."
  fi

  # Try using light if available
  if check_command_exists "light"; then
    local light_output
    light_output=$(light -G 2>/dev/null)
    if [[ $? -eq 0 && -n "$light_output" ]]; then
      brightness=$(echo "$light_output" | awk '{print int($1)}')
      if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
        success=true
        log "Got brightness $brightness% via light"
        echo "$brightness"
        return
      fi
    fi
    log "WARNING: Failed to get valid brightness from light."
  fi

  # Try using xbacklight if available (X11 only)
  if check_command_exists "xbacklight"; then
    local xbacklight_output
    xbacklight_output=$(xbacklight -get 2>/dev/null)
    if [[ $? -eq 0 && -n "$xbacklight_output" ]]; then
      brightness=$(echo "$xbacklight_output" | awk '{print int($1)}')
      if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
        success=true
        log "Got brightness $brightness% via xbacklight"
        echo "$brightness"
        return
      fi
    fi
    log "WARNING: Failed to get valid brightness from xbacklight."
  fi

  # Try direct sysfs method for Linux - with added error handling
  for backlight_dir in /sys/class/backlight/*; do
    if [[ -d "$backlight_dir" && -f "$backlight_dir/brightness" && -f "$backlight_dir/max_brightness" ]]; then
      local current max
      current=$(cat "$backlight_dir/brightness" 2>/dev/null)
      max=$(cat "$backlight_dir/max_brightness" 2>/dev/null)

      if [[ $? -eq 0 && -n "$current" && -n "$max" && "$current" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
        brightness=$(awk "BEGIN {print int(($current / $max) * 100)}")
        if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
          success=true
          log "Got brightness $brightness% via sysfs ($backlight_dir)"
          echo "$brightness"
          return
        fi
      fi
    fi
  done

  if ! $success; then
    log "WARNING: No supported brightness control method found. Using default: $brightness%"
  fi

  echo "$brightness" # Return default value
}

# Function to set screen brightness with improved error handling
set_brightness() {
  local brightness_percent=$1
  local success=false

  # Validate input and enforce safety limits (never below 5%)
  if [[ ! "$brightness_percent" =~ ^[0-9]+$ ]] || [ "$brightness_percent" -lt 5 ] || [ "$brightness_percent" -gt 100 ]; then
    log "WARNING: Invalid brightness value ($brightness_percent). Using 20% as safety default."
    brightness_percent=20
  fi

  log "Setting brightness to $brightness_percent%"

  # Try using brightnessctl if available
  if check_command_exists "brightnessctl"; then
    brightnessctl s "$brightness_percent%" -q 2>/dev/null
    if [[ $? -eq 0 ]]; then
      log "Successfully set brightness to $brightness_percent% using brightnessctl"
      success=true
      return 0
    fi
    log "Failed to set brightness using brightnessctl."
  fi

  # Try using light if available
  if check_command_exists "light"; then
    light -S "$brightness_percent" 2>/dev/null
    if [[ $? -eq 0 ]]; then
      log "Successfully set brightness to $brightness_percent% using light"
      success=true
      return 0
    fi
    log "Failed to set brightness using light."
  fi

  # Try using xbacklight if available (X11 only)
  if check_command_exists "xbacklight"; then
    xbacklight -set "$brightness_percent" 2>/dev/null
    if [[ $? -eq 0 ]]; then
      log "Successfully set brightness to $brightness_percent% using xbacklight"
      success=true
      return 0
    fi
    log "Failed to set brightness using xbacklight."
  fi

  # Last resort: try to use direct sysfs method if we find a compatible backlight device
  for backlight_dir in /sys/class/backlight/*; do
    if [[ -d "$backlight_dir" && -f "$backlight_dir/brightness" && -f "$backlight_dir/max_brightness" && -w "$backlight_dir/brightness" ]]; then
      local max
      max=$(cat "$backlight_dir/max_brightness" 2>/dev/null)

      if [[ $? -eq 0 && -n "$max" && "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
        # Calculate the raw brightness value based on percentage
        local raw_value
        raw_value=$(echo "$max * $brightness_percent / 100" | bc 2>/dev/null)

        if [[ $? -eq 0 && -n "$raw_value" ]]; then
          # Try to set the brightness directly (might require root privileges)
          echo "$raw_value" > "$backlight_dir/brightness" 2>/dev/null
          if [[ $? -eq 0 ]]; then
            log "Successfully set brightness to $brightness_percent% using sysfs ($backlight_dir)"
            success=true
            return 0
          fi
        fi
      fi
    fi
  done

  if ! $success; then
    log "ERROR: Failed to set brightness using any available method."
    return 1
  fi
}

# Function to adjust brightness based on battery percentage
adjust_brightness_for_battery() {
  local battery_percent=$1
  local ac_status=$2
  local target_brightness

  # Skip brightness adjustment if feature is disabled
  if [ "$BRIGHTNESS_CONTROL_ENABLED" != "true" ]; then
    return
  fi

  # When charging, use maximum brightness or high brightness depending on battery level
  if [ "$ac_status" == "Charging" ]; then
    # When charging but battery not yet almost full, use a slightly reduced brightness
    if [ "$battery_percent" -lt "$BATTERY_ALMOST_FULL_THRESHOLD" ]; then
      target_brightness=$BRIGHTNESS_VERY_HIGH
    else
      # When charging and battery almost full or full, use maximum brightness
      target_brightness=$BRIGHTNESS_MAX
    fi
  else
    # When on battery, adjust brightness based on the battery percentage
    if [ "$battery_percent" -le "$CRITICAL_THRESHOLD" ]; then
      target_brightness=$BRIGHTNESS_CRITICAL
    elif [ "$battery_percent" -le "$BATTERY_LOW_THRESHOLD" ]; then
      target_brightness=$BRIGHTNESS_VERY_LOW
    elif [ "$battery_percent" -le "$BATTERY_MEDIUM_LOW_THRESHOLD" ]; then
      target_brightness=$BRIGHTNESS_LOW
    elif [ "$battery_percent" -le "$BATTERY_MEDIUM_THRESHOLD" ]; then
      target_brightness=$BRIGHTNESS_MEDIUM_LOW
    elif [ "$battery_percent" -le "$BATTERY_MEDIUM_HIGH_THRESHOLD" ]; then
      target_brightness=$BRIGHTNESS_MEDIUM
    elif [ "$battery_percent" -le "$BATTERY_HIGH_THRESHOLD" ]; then
      target_brightness=$BRIGHTNESS_MEDIUM_HIGH
    elif [ "$battery_percent" -le "$BATTERY_VERY_HIGH_THRESHOLD" ]; then
      target_brightness=$BRIGHTNESS_HIGH
    else
      # Above very high threshold
      target_brightness=$BRIGHTNESS_VERY_HIGH
    fi
  fi

  # Get current brightness
  local current_brightness
  current_brightness=$(get_current_brightness)

  # Only change brightness if it differs significantly from target
  if [ $((current_brightness - target_brightness)) -ge 5 ] || [ $((target_brightness - current_brightness)) -ge 5 ]; then
    log "Adjusting brightness from $current_brightness% to $target_brightness% based on battery level ($battery_percent%)"
    set_brightness "$target_brightness"

    # Only notify if the change is significant
    if [ $((current_brightness - target_brightness)) -ge 15 ] || [ $((target_brightness - current_brightness)) -ge 15 ]; then
      send_notification_safely "Battery Saver" "Screen brightness adjusted to $target_brightness% (Battery: $battery_percent%)" "low"
    fi
  fi
}

# Function to safely send notifications with error handling
send_notification_safely() {
  local title="$1"
  local message="$2"
  local urgency="$3"

  notify-send -u "$urgency" "$title" "$message" 2>/dev/null ||
    log "WARNING: Failed to send notification: '$title' - '$message'"
}

# Function to send notification based on battery level
send_notification() {
  local battery_percent=$1
  local ac_status=$2
  local notification_type=""

  if [ "$battery_percent" -le "$CRITICAL_THRESHOLD" ]; then
    notification_type="critical"
    log "Battery is critically low at $battery_percent%. Sending critical notification."
    send_notification_safely "Battery Warning" "Battery is at $battery_percent%. Please plug in the charger." "critical"
  elif [ "$battery_percent" -le "$LOW_THRESHOLD" ]; then
    notification_type="low"
    log "Battery is low at $battery_percent%. Sending low notification."
    send_notification_safely "Battery Warning" "Battery is at $battery_percent%. Consider plugging in the charger." "normal"
  elif [ "$battery_percent" -ge "$FULL_BATTERY_THRESHOLD" ] && [ "$ac_status" == "Charging" ]; then
    notification_type="full"
    log "Battery is fully charged at $battery_percent%. Sending notification."
    send_notification_safely "Battery Info" "Battery is fully charged ($battery_percent%)." "normal"
  else
    return 0 # No notification needed
  fi

  # Save last notification type and time to avoid duplicate notifications
  echo "${notification_type}:$(date +%s)" >"/tmp/battery_notification_last"
}

# Function to determine sleep duration based on battery percentage
get_sleep_duration() {
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

# Check if a notification should be suppressed due to cooldown
should_send_notification() {
  local battery_percent=$1
  local ac_status=$2
  local notification_type=""

  # Determine notification type based on battery percentage
  if [ "$battery_percent" -le "$CRITICAL_THRESHOLD" ]; then
    notification_type="critical"
  elif [ "$battery_percent" -le "$LOW_THRESHOLD" ]; then
    notification_type="low"
  elif [ "$battery_percent" -ge "$FULL_BATTERY_THRESHOLD" ] && [ "$ac_status" == "Charging" ]; then
    notification_type="full"
  else
    return 1 # No notification needed
  fi

  # Check if we've sent this notification recently
  if [ -f "/tmp/battery_notification_last" ]; then
    local last_notification
    last_notification=$(cat "/tmp/battery_notification_last")
    if [[ $? -ne 0 ]]; then
      log "WARNING: Failed to read last notification info."
      return 0 # Assume we should send notification
    fi

    local last_type=${last_notification%:*}
    local last_time=${last_notification#*:}
    local current_time
    current_time=$(date +%s)
    if [[ $? -ne 0 ]]; then
      log "WARNING: Failed to get current time."
      return 0 # Assume we should send notification
    fi

    # If same notification type was sent within cooldown period, skip it
    if [ "$notification_type" == "$last_type" ] &&
      ((current_time - last_time < NOTIFICATION_COOLDOWN)); then
      return 1 # Skip notification
    fi
  fi

  return 0 # Send notification
}

# log the start of the script
log "Battery Warning script started at $(date +'%Y-%m-%d %H:%M:%S')"

# Initialize variables
previous_ac_status="Unknown"
previous_battery_percent=0

# Add this function before the main loop
check_battery_exists() {
  log "Checking for battery presence..."

  # Check for battery in /sys/class/power_supply
  for bat in /sys/class/power_supply/BAT*; do
    if [[ -d "$bat" ]]; then
      log "Battery found at $bat"
      return 0
    fi
  done

  # Try alternate battery paths (some systems use different naming)
  for alt_bat in /sys/class/power_supply/*; do
    if [[ -d "$alt_bat" && -f "$alt_bat/capacity" && -f "$alt_bat/type" ]]; then
      local type=$(cat "$alt_bat/type" 2>/dev/null)
      if [[ "$type" == "Battery" ]]; then
        log "Battery found at $alt_bat"
        return 0
      fi
    fi
  done

  # Try using acpi as fallback
  if check_command_exists "acpi"; then
    if acpi -b 2>/dev/null | grep -q "Battery"; then
      log "Battery detected via acpi command"
      return 0
    fi
  fi

  log "No battery detected on this system"
  return 1
}

# Use it in the main script
if ! check_battery_exists; then
  log "No battery detected. Exiting."
  exit 0
fi

# Call validation after configuration but before main loop
validate_config

# Main loop
while true; do
  # Get the battery percentage with error checking
  battery_percent=$(check_battery)
  if [[ ! "$battery_percent" =~ ^[0-9]+$ ]]; then
    log "ERROR: Invalid battery percentage: '$battery_percent'. Using previous value: $previous_battery_percent"
    battery_percent=$previous_battery_percent
  fi

  # Get AC status with error checking
  ac_status=$(check_ac_status)
  if [[ "$ac_status" != "Charging" && "$ac_status" != "Discharging" ]]; then
    log "WARNING: Unrecognized AC status: '$ac_status'. Using previous value: $previous_ac_status"
    ac_status=$previous_ac_status
  fi

  # Log current status (only if changed to reduce log size)
  if [ "$battery_percent" != "$previous_battery_percent" ] || [ "$ac_status" != "$previous_ac_status" ]; then
    log "Battery: $battery_percent%, AC: $ac_status"
  fi

  # Handle AC connection state changes
  if [ "$ac_status" == "Charging" ] && [ "$previous_ac_status" != "Charging" ]; then
    log "AC power connected."
    send_notification_safely "Battery Info" "AC power connected." "normal"
    # Set brightness to high when AC is connected
    set_brightness "$BRIGHTNESS_HIGH"
  elif [ "$ac_status" == "Discharging" ] && [ "$previous_ac_status" == "Charging" ]; then
    log "AC power disconnected."
    send_notification_safely "Battery Info" "AC power disconnected." "normal"
    # Adjust brightness immediately when switching to battery
    adjust_brightness_for_battery "$battery_percent" "$ac_status"
  fi

  # Check battery levels and issue notifications if needed
  if should_send_notification "$battery_percent" "$ac_status"; then
    send_notification "$battery_percent" "$ac_status"
  fi

  # Take critical actions for extremely low battery
  if [ "$battery_percent" -le 5 ] && [ "$ac_status" == "Discharging" ]; then
    # Send emergency notification
    send_notification_safely "CRITICAL BATTERY LEVEL" "Battery at $battery_percent%! System may shut down soon!" "critical"

    # Log the critical state
    log "CRITICAL: Battery at $battery_percent%. Taking emergency actions."

    # Optional: Trigger system actions (hibernation/suspension)
    # Uncomment the appropriate line for your system if desired

    # For systemd systems:
    # if check_command_exists "systemctl"; then
    #   log "Attempting to hibernate system due to critical battery level"
    #   systemctl hibernate || systemctl suspend
    # fi

    # For non-systemd systems:
    # if check_command_exists "pm-hibernate"; then
    #   log "Attempting to hibernate system due to critical battery level"
    #   pm-hibernate || pm-suspend
    # fi
  fi

  # Adjust brightness based on battery percentage
  adjust_brightness_for_battery "$battery_percent" "$ac_status"

  # Determine sleep duration based on battery status
  sleep_duration=$(get_sleep_duration "$battery_percent" "$ac_status")
  # Validate sleep duration
  if [[ ! "$sleep_duration" =~ ^[0-9]+$ ]] || [ "$sleep_duration" -lt 30 ]; then
    log "WARNING: Invalid sleep duration: '$sleep_duration'. Using safe default of 60 seconds."
    sleep_duration=60
  fi

  # Update previous values
  previous_ac_status="$ac_status"
  previous_battery_percent="$battery_percent"

  # Sleep before checking again
  log "Sleeping for $sleep_duration seconds."
  sleep "$sleep_duration"
done
