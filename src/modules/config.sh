#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Configuration management module
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

# Define configuration paths if not already set
if [[ -z "${BG_DEFAULT_CONFIG:-}" ]]; then
  # Check if BG_PARENT_DIR is already set, don't try to modify it
  bg_parent_dir=""
  if [[ -n "${BG_PARENT_DIR:-}" ]]; then
    bg_parent_dir="$BG_PARENT_DIR"
  else
    bg_parent_dir="$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")"
  fi
  
  BG_DEFAULT_CONFIG="$bg_parent_dir/configs/defaults.sh"
  
  # XDG based user config
  XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
  BG_CONFIG_DIR="${XDG_CONFIG_HOME}/battery-guardian"
  BG_USER_CONFIG="${BG_CONFIG_DIR}/config.sh"
fi

# ---- User Configuration Management ----
# Ensures a user configuration file exists for customization
bg_ensure_user_config_exists() {
  # If user config already exists, we don't need to do anything
  if [[ -f "$BG_USER_CONFIG" ]]; then
    return 0
  fi

  bg_info "User configuration file doesn't exist. Creating at $BG_USER_CONFIG"

  # Ensure config directory exists
  if ! mkdir -p "$(dirname "$BG_USER_CONFIG")" 2>/dev/null; then
    bg_error "Failed to create configuration directory $(dirname "$BG_USER_CONFIG")"
    return 1
  fi

  # Create the user config file with defaults and comments
  cat >"$BG_USER_CONFIG" <<EOF
#!/usr/bin/env bash
# BatteryGuardian User Configuration
# ----------------------------------
# This file contains your personal configuration settings for BatteryGuardian.
# You can modify these values to customize how BatteryGuardian works.
# Default values are loaded from the system defaults, and then overridden by
# any values you set here.

# Battery threshold settings
# -------------------------
# bg_LOW_THRESHOLD: Battery percentage to trigger low battery warning
# bg_CRITICAL_THRESHOLD: Battery percentage to trigger critical battery warning
# bg_FULL_BATTERY_THRESHOLD: Battery percentage to consider battery fully charged
# bg_BATTERY_ALMOST_FULL_THRESHOLD: Battery percentage to consider almost full

# Uncomment and change values to override defaults:
# bg_LOW_THRESHOLD=20
# bg_CRITICAL_THRESHOLD=10
# bg_FULL_BATTERY_THRESHOLD=90
# bg_BATTERY_ALMOST_FULL_THRESHOLD=85

# Notification settings
# --------------------
# bg_NOTIFICATION_COOLDOWN: Seconds between identical notifications

# Uncomment and change values to override defaults:
# bg_NOTIFICATION_COOLDOWN=300

# Brightness control settings
# --------------------------
# Set to false to disable automatic brightness adjustment
# bg_BRIGHTNESS_CONTROL_ENABLED=true

# Brightness levels for different battery states
# ---------------------------------------------
# Values are in percentage (0-100)
# BRIGHTNESS_MAX: Maximum brightness (for AC power)
# BRIGHTNESS_VERY_HIGH: For battery >85%
# BRIGHTNESS_HIGH: For battery >70%
# BRIGHTNESS_MEDIUM_HIGH: For battery >60%
# BRIGHTNESS_MEDIUM: For battery >50%
# BRIGHTNESS_MEDIUM_LOW: For battery >30%
# BRIGHTNESS_LOW: For battery >20%
# BRIGHTNESS_VERY_LOW: For battery >10%
# BRIGHTNESS_CRITICAL: For critical battery <=10%

# Uncomment and change values to override defaults:
# bg_BRIGHTNESS_MAX=100
# bg_BRIGHTNESS_VERY_HIGH=95
# bg_BRIGHTNESS_HIGH=85
# bg_BRIGHTNESS_MEDIUM_HIGH=70
# bg_BRIGHTNESS_MEDIUM=60
# bg_BRIGHTNESS_MEDIUM_LOW=45
# bg_BRIGHTNESS_LOW=35
# bg_BRIGHTNESS_VERY_LOW=25
# bg_BRIGHTNESS_CRITICAL=15

# Battery threshold percentages for brightness changes
# --------------------------------------------------
# bg_BATTERY_VERY_HIGH_THRESHOLD=85
# bg_BATTERY_HIGH_THRESHOLD=70
# bg_BATTERY_MEDIUM_HIGH_THRESHOLD=60
# bg_BATTERY_MEDIUM_THRESHOLD=50
# bg_BATTERY_MEDIUM_LOW_THRESHOLD=30
# bg_BATTERY_LOW_THRESHOLD=20
# Critical threshold is already defined above
EOF

  # Check if the file was successfully created
  if [[ ! -f "$BG_USER_CONFIG" ]]; then
    bg_error "Failed to create user configuration file at $BG_USER_CONFIG"
    return 1
  fi

  # Set appropriate permissions (644 = rw-r--r--)
  chmod 644 "$BG_USER_CONFIG" 2>/dev/null || {
    bg_warn "Failed to set permissions on $BG_USER_CONFIG"
  }

  bg_info "User configuration file created successfully"
  return 0
}

# ---- Lock Management ----
# Create lock file to prevent multiple instances
bg_check_lock() {
  if [[ -f "$BG_LOCK_FILE" ]]; then
    # Check if the process is still running
    local oldpid
    oldpid=$(cat "$BG_LOCK_FILE" 2>/dev/null)
    if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
      bg_info "Script is already running with PID $oldpid. Exiting."
      exit 0
    else
      bg_warn "Found stale lock file. Previous process seems to have died unexpectedly."
    fi
  fi
  # Create lockfile
  echo $$ >"$BG_LOCK_FILE" || {
    bg_error "Failed to create lock file. Continuing without lock."
  }
}

# ---- Cleanup Function ----
bg_cleanup() {
  bg_info "Battery monitoring script terminated."
  rm -f "$BG_LOCK_FILE"
  exit 0
}

# Set up trap for clean exit
trap bg_cleanup SIGINT SIGTERM EXIT

# ---- Configuration Loading ----
# Load and validate configuration
bg_load_config() {
  # Start with default values
  if [[ -f "$BG_DEFAULT_CONFIG" ]]; then
    bg_info "Loading default configuration from $BG_DEFAULT_CONFIG"
    # shellcheck source=/dev/null
    source "$BG_DEFAULT_CONFIG"
  else
    bg_error "Default configuration file not found at $BG_DEFAULT_CONFIG"
  fi

  # Ensure user configuration exists (create if necessary)
  bg_ensure_user_config_exists

  # Load user configuration if it exists
  if [[ -f "$BG_USER_CONFIG" ]]; then
    bg_info "Loading user configuration from $BG_USER_CONFIG"
    # shellcheck source=/dev/null
    source "$BG_USER_CONFIG"
  else
    bg_info "No user configuration found at $BG_USER_CONFIG"
  fi

  bg_validate_config
}

# ---- Configuration Validation ----
bg_validate_config() {
  local has_errors=false

  # Validate thresholds
  if [[ ! "$bg_LOW_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$bg_LOW_THRESHOLD" -lt 5 ] || [ "$bg_LOW_THRESHOLD" -gt 50 ]; then
    bg_error "Invalid bg_LOW_THRESHOLD value: $bg_LOW_THRESHOLD. Setting to default 20%."
    bg_LOW_THRESHOLD=20
    has_errors=true
  fi

  if [[ ! "$bg_CRITICAL_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$bg_CRITICAL_THRESHOLD" -lt 3 ] || [ "$bg_CRITICAL_THRESHOLD" -gt "$bg_LOW_THRESHOLD" ]; then
    bg_error "Invalid bg_CRITICAL_THRESHOLD value: $bg_CRITICAL_THRESHOLD. Setting to default 10%."
    bg_CRITICAL_THRESHOLD=10
    has_errors=true
  fi

  if [[ ! "$bg_FULL_BATTERY_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$bg_FULL_BATTERY_THRESHOLD" -lt 80 ] || [ "$bg_FULL_BATTERY_THRESHOLD" -gt 100 ]; then
    bg_error "Invalid bg_FULL_BATTERY_THRESHOLD value: $bg_FULL_BATTERY_THRESHOLD. Setting to default 90%."
    bg_FULL_BATTERY_THRESHOLD=90
    has_errors=true
  fi

  # Validate brightness values
  if [ "$bg_BRIGHTNESS_CONTROL_ENABLED" != "true" ] && [ "$bg_BRIGHTNESS_CONTROL_ENABLED" != "false" ]; then
    bg_error "Invalid bg_BRIGHTNESS_CONTROL_ENABLED value. Setting to default (true)."
    bg_BRIGHTNESS_CONTROL_ENABLED=true
    has_errors=true
  fi

  # Validate brightness levels (ensure they're all valid integers)
  local brightness_vars=(bg_BRIGHTNESS_MAX bg_BRIGHTNESS_VERY_HIGH bg_BRIGHTNESS_HIGH bg_BRIGHTNESS_MEDIUM_HIGH
    bg_BRIGHTNESS_MEDIUM bg_BRIGHTNESS_MEDIUM_LOW bg_BRIGHTNESS_LOW bg_BRIGHTNESS_VERY_LOW bg_BRIGHTNESS_CRITICAL)

  for var_name in "${brightness_vars[@]}"; do
    local value=${!var_name}
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 5 ] || [ "$value" -gt 100 ]; then
      bg_error "Invalid $var_name value: $value. Setting to safe default."
      # Set default based on variable name
      case "$var_name" in
      bg_BRIGHTNESS_MAX) eval "$var_name=100" ;;
      bg_BRIGHTNESS_VERY_HIGH) eval "$var_name=95" ;;
      bg_BRIGHTNESS_HIGH) eval "$var_name=85" ;;
      bg_BRIGHTNESS_MEDIUM_HIGH) eval "$var_name=70" ;;
      bg_BRIGHTNESS_MEDIUM) eval "$var_name=60" ;;
      bg_BRIGHTNESS_MEDIUM_LOW) eval "$var_name=45" ;;
      bg_BRIGHTNESS_LOW) eval "$var_name=35" ;;
      bg_BRIGHTNESS_VERY_LOW) eval "$var_name=25" ;;
      bg_BRIGHTNESS_CRITICAL) eval "$var_name=15" ;;
      esac
      has_errors=true
    fi
  done

  # Ensure brightness thresholds are in descending order
  if [ "$bg_BRIGHTNESS_MAX" -lt "$bg_BRIGHTNESS_VERY_HIGH" ] ||
    [ "$bg_BRIGHTNESS_VERY_HIGH" -lt "$bg_BRIGHTNESS_HIGH" ] ||
    [ "$bg_BRIGHTNESS_HIGH" -lt "$bg_BRIGHTNESS_MEDIUM_HIGH" ] ||
    [ "$bg_BRIGHTNESS_MEDIUM_HIGH" -lt "$bg_BRIGHTNESS_MEDIUM" ] ||
    [ "$bg_BRIGHTNESS_MEDIUM" -lt "$bg_BRIGHTNESS_MEDIUM_LOW" ] ||
    [ "$bg_BRIGHTNESS_MEDIUM_LOW" -lt "$bg_BRIGHTNESS_LOW" ] ||
    [ "$bg_BRIGHTNESS_LOW" -lt "$bg_BRIGHTNESS_VERY_LOW" ] ||
    [ "$bg_BRIGHTNESS_VERY_LOW" -lt "$bg_BRIGHTNESS_CRITICAL" ]; then
    bg_error "Brightness values not in descending order. Some values will be adjusted."

    # Ensure a sane minimum
    [ "$bg_BRIGHTNESS_CRITICAL" -lt 10 ] && bg_BRIGHTNESS_CRITICAL=10

    # Fix ascending order if needed
    [ "$bg_BRIGHTNESS_VERY_LOW" -le "$bg_BRIGHTNESS_CRITICAL" ] && bg_BRIGHTNESS_VERY_LOW=$((bg_BRIGHTNESS_CRITICAL + 5))
    [ "$bg_BRIGHTNESS_LOW" -le "$bg_BRIGHTNESS_VERY_LOW" ] && bg_BRIGHTNESS_LOW=$((bg_BRIGHTNESS_VERY_LOW + 5))
    [ "$bg_BRIGHTNESS_MEDIUM_LOW" -le "$bg_BRIGHTNESS_LOW" ] && bg_BRIGHTNESS_MEDIUM_LOW=$((bg_BRIGHTNESS_LOW + 5))
    [ "$bg_BRIGHTNESS_MEDIUM" -le "$bg_BRIGHTNESS_MEDIUM_LOW" ] && bg_BRIGHTNESS_MEDIUM=$((bg_BRIGHTNESS_MEDIUM_LOW + 5))
    [ "$bg_BRIGHTNESS_MEDIUM_HIGH" -le "$bg_BRIGHTNESS_MEDIUM" ] && bg_BRIGHTNESS_MEDIUM_HIGH=$((bg_BRIGHTNESS_MEDIUM + 5))
    [ "$bg_BRIGHTNESS_HIGH" -le "$bg_BRIGHTNESS_MEDIUM_HIGH" ] && bg_BRIGHTNESS_HIGH=$((bg_BRIGHTNESS_MEDIUM_HIGH + 5))
    [ "$bg_BRIGHTNESS_VERY_HIGH" -le "$bg_BRIGHTNESS_HIGH" ] && bg_BRIGHTNESS_VERY_HIGH=$((bg_BRIGHTNESS_HIGH + 5))
    [ "$bg_BRIGHTNESS_MAX" -le "$bg_BRIGHTNESS_VERY_HIGH" ] && bg_BRIGHTNESS_MAX=$((bg_BRIGHTNESS_VERY_HIGH + 5))

    # Cap at 100%
    [ "$bg_BRIGHTNESS_MAX" -gt 100 ] && bg_BRIGHTNESS_MAX=100
    has_errors=true
  fi

  # Print all configuration values if there were errors
  if [ "$has_errors" = true ]; then
    bg_info "Fixed configuration values:"
    bg_info "bg_LOW_THRESHOLD=$bg_LOW_THRESHOLD, bg_CRITICAL_THRESHOLD=$bg_CRITICAL_THRESHOLD, bg_FULL_BATTERY_THRESHOLD=$bg_FULL_BATTERY_THRESHOLD"
    bg_info "bg_BRIGHTNESS_MAX=$bg_BRIGHTNESS_MAX, bg_BRIGHTNESS_VERY_HIGH=$bg_BRIGHTNESS_VERY_HIGH, bg_BRIGHTNESS_HIGH=$bg_BRIGHTNESS_HIGH"
    bg_info "bg_BRIGHTNESS_MEDIUM_HIGH=$bg_BRIGHTNESS_MEDIUM_HIGH, bg_BRIGHTNESS_MEDIUM=$bg_BRIGHTNESS_MEDIUM"
    bg_info "bg_BRIGHTNESS_MEDIUM_LOW=$bg_BRIGHTNESS_MEDIUM_LOW, bg_BRIGHTNESS_LOW=$bg_BRIGHTNESS_LOW"
    bg_info "bg_BRIGHTNESS_VERY_LOW=$bg_BRIGHTNESS_VERY_LOW, bg_BRIGHTNESS_CRITICAL=$bg_BRIGHTNESS_CRITICAL"
  fi
}
