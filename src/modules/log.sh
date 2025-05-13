#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Logging module - provides logging functionality
# Author: Cyber-Syntax
# License: BSD 3-Clause License
# --------------------------------------------------------

# Ensure script exits on errors and undefined variables when sourced directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -o errexit -o nounset -o pipefail
else
  # When sourced by another script, still use these options
  set -o pipefail
fi

# ---- XDG Base Directories ----
# Set XDG directories with fallbacks
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# Application-specific directories
BG_CONFIG_DIR="${XDG_CONFIG_HOME}/battery-guardian"
BG_STATE_DIR="${XDG_STATE_HOME}/battery-guardian"
BG_RUNTIME_DIR="${XDG_RUNTIME_DIR}/battery-guardian"

# Log rotation settings
BG_MAX_LOG_SIZE=1048576 # 1MB in bytes
BG_MAX_LOG_COUNT=3      # Keep 3 rotated log files

# Create necessary directories
mkdir -p "${BG_CONFIG_DIR}" 2>/dev/null || true
mkdir -p "${BG_STATE_DIR}/logs" 2>/dev/null || true
mkdir -p "${BG_RUNTIME_DIR}" 2>/dev/null || {
  # Fallback to /tmp if XDG_RUNTIME_DIR can't be used
  BG_RUNTIME_DIR="/tmp/battery-guardian"
  mkdir -p "${BG_RUNTIME_DIR}" 2>/dev/null || true
}

# ---- Configuration Files ----
if [[ -z "${BG_DEFAULT_CONFIG:-}" ]]; then
  if [[ -n "${BASH_SOURCE[0]}" ]]; then
    # When sourced, use the module's location to determine the config path
    # Check if BG_PARENT_DIR is set (readonly) and use it if available
    if [[ -n "${BG_PARENT_DIR:-}" ]]; then
      BG_DEFAULT_CONFIG="$BG_PARENT_DIR/configs/defaults.sh"
    else
      BG_DEFAULT_CONFIG="$(dirname "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")")/configs/defaults.sh"
    fi
  else
    # Fallback when executed directly
    BG_DEFAULT_CONFIG="$(dirname "$(dirname "$(readlink -f "$0")")")/configs/defaults.sh"
  fi
fi

# Define user config path if not already set
BG_USER_CONFIG="${BG_USER_CONFIG:-${BG_CONFIG_DIR}/config.sh}"

# ---- Runtime Files ----
BG_LOG_FILE="${BG_STATE_DIR}/logs/battery.log"
BG_LOCK_FILE="${BG_RUNTIME_DIR}/battery_monitor.lock"
BG_NOTIFICATION_FILE="${BG_RUNTIME_DIR}/last_notification"

# Export path variables so they're available to all modules
export BG_CONFIG_DIR BG_STATE_DIR BG_RUNTIME_DIR
export BG_LOG_FILE BG_LOCK_FILE BG_NOTIFICATION_FILE
export BG_DEFAULT_CONFIG BG_USER_CONFIG

# ---- Cached Paths ----
bg_BATTERY_PATH="" # Will be populated when a working battery path is found
bg_AC_PATH=""      # Will be populated when a working AC path is found
export bg_BATTERY_PATH bg_AC_PATH

# ---- Log Rotation Function ----
# Rotates log files when they grow too large
bg_rotate_logs() {
  # If log file doesn't exist yet, nothing to rotate
  if [[ ! -f "$BG_LOG_FILE" ]]; then
    return 0
  fi

  # Check current log file size
  local log_size
  if ! log_size=$(stat -c %s "$BG_LOG_FILE" 2>/dev/null); then
    # Fallback to wc if stat fails
    log_size=$(wc -c <"$BG_LOG_FILE" 2>/dev/null) || {
      # Cannot check size - may be permissions or non-existent file
      return 1
    }
  fi

  # If log file is smaller than max size, no rotation needed
  # Use variable from environment if set, otherwise use default
  if [[ "$log_size" -lt "${BG_MAX_LOG_SIZE:-1048576}" ]]; then
    return 0
  fi

  # Get the log directory and ensure it exists
  local log_dir
  log_dir=$(dirname "$BG_LOG_FILE")
  mkdir -p "$log_dir" 2>/dev/null || {
    echo "ERROR: Failed to create log directory for rotation. Using /tmp." >&2
    log_dir="/tmp"
  }

  # Get log file base name without path
  local log_base
  log_base=$(basename "$BG_LOG_FILE")

  # Perform rotation
  local full_path="$log_dir/$log_base"

  # Remove the oldest log if it exists
  if [[ -f "${full_path}.${BG_MAX_LOG_COUNT}" ]]; then
    rm "${full_path}.${BG_MAX_LOG_COUNT}" 2>/dev/null ||
      echo "WARNING: Failed to remove oldest log file: ${full_path}.${BG_MAX_LOG_COUNT}" >&2
  fi

  # Shift the other logs
  for ((i = BG_MAX_LOG_COUNT - 1; i > 0; i--)); do
    local j=$((i + 1))
    if [[ -f "${full_path}.$i" ]]; then
      mv "${full_path}.$i" "${full_path}.$j" 2>/dev/null ||
        echo "WARNING: Failed to rotate log from ${full_path}.$i to ${full_path}.$j" >&2
    fi
  done

  # Move the current log to .1
  mv "$full_path" "${full_path}.1" 2>/dev/null || {
    echo "WARNING: Failed to rotate current log to ${full_path}.1" >&2
    # If we can't rotate, try to clear the current log instead
    : >"$full_path" 2>/dev/null ||
      echo "ERROR: Failed to clear current log. Log entries may be lost." >&2
  }

  return 0
}

# ---- Logging Function ----
# Log messages with timestamps
bg_log() {
  local level="$1"
  local message="$2"
  local level_num=0
  
  # Set default log level to INFO (3) if not specified
  local log_level=${BG_LOG_LEVEL:-3}
  
  # Convert log level string to number
  case "$level" in
    "DEBUG")   level_num=4 ;;
    "INFO")    level_num=3 ;;
    "WARNING") level_num=2 ;;
    "ERROR")   level_num=1 ;;
    *)         level_num=3 ;; # Default to INFO level
  esac
  
  # Only log if the message's level is less than or equal to the configured level
  if [[ "$level_num" -gt "$log_level" ]]; then
    return 0
  fi
  
  local datetime
  datetime=$(date +'%Y-%m-%d %H:%M:%S')

  # Create log directory if it doesn't exist yet
  mkdir -p "$(dirname "$BG_LOG_FILE")" 2>/dev/null || {
    BG_LOG_FILE="/tmp/battery-guardian.log"
    echo "WARNING: Could not create log directory, using fallback log file: $BG_LOG_FILE" >&2
  }

  # Rotate logs if necessary before writing
  bg_rotate_logs

  # Write log entry to a new file if rotation happened
  if [[ ! -f "$BG_LOG_FILE" ]]; then
    # After rotation, the file may not exist, so create it with the new entry
    echo "[$datetime] [$level] $message" >"$BG_LOG_FILE"
  else
    # Append to existing file
    echo "[$datetime] [$level] $message" >>"$BG_LOG_FILE"
  fi

  # For error and warning levels, also print to stderr
  if [[ "$level" == "ERROR" || "$level" == "WARNING" ]]; then
    echo "[$level] $message" >&2
  fi
}

# Log level wrappers
bg_debug() { bg_log "DEBUG" "$1"; }
bg_info() { bg_log "INFO" "$1"; }
bg_warn() { bg_log "WARNING" "$1"; }
bg_error() { bg_log "ERROR" "$1"; }
