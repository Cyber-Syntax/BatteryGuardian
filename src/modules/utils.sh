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

  # Check for event monitoring tools
  if ! bg_check_command_exists "inotifywait"; then
    bg_warn "inotifywait not found. Event-based battery monitoring may be limited."
    bg_warn "Consider installing inotify-tools package for better power event handling."
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

# Initialize global back-off tracking variables
bg_current_backoff_interval=${bg_BACKOFF_INITIAL:-10}

# Get adaptive sleep duration with exponential back-off
bg_get_sleep_duration() {
  local battery_percent=$1
  local ac_status=$2
  local has_changed=$3  # 1 if battery status changed, 0 otherwise
  local duration
  
  # Reset back-off when actual changes are detected
  if [[ "$has_changed" -eq 1 ]]; then
    bg_current_backoff_interval=${bg_BACKOFF_INITIAL:-10}
    bg_info "Battery status changed - resetting back-off interval to ${bg_current_backoff_interval}s"
    duration=$bg_current_backoff_interval
  else
    # Use current back-off value 
    duration=$bg_current_backoff_interval
    
    # Apply exponential back-off for next time
    bg_current_backoff_interval=$((bg_current_backoff_interval * ${bg_BACKOFF_FACTOR:-2}))
    
    # Cap at maximum
    if [[ "$bg_current_backoff_interval" -gt "${bg_BACKOFF_MAX:-300}" ]]; then
      bg_current_backoff_interval=${bg_BACKOFF_MAX:-300}
    fi
    
    # If current value is already over max, cap it too
    if [[ "$duration" -gt "${bg_BACKOFF_MAX:-300}" ]]; then
      duration=${bg_BACKOFF_MAX:-300}
      bg_info "Capping sleep duration to maximum ${duration}s"
    fi
  fi
  
  # Special case: for critical battery, always check more frequently
  if [[ "$battery_percent" -le 5 && "$ac_status" == "Discharging" ]]; then
    duration=${bg_CRITICAL_POLLING:-30}
    bg_info "Critical battery level - using fixed polling interval of ${duration}s"
  fi

  echo "$duration"
}

# Check battery status and adjust brightness accordingly
check_battery_and_adjust_brightness() {
  # Make sure brightness module is loaded
  if [[ -z "${bg_BRIGHTNESS_MAX:-}" ]]; then
    source "$BG_SCRIPT_DIR/modules/brightness.sh"
  fi

  # Get the battery percentage with error checking
  local battery_percent
  battery_percent=$(bg_check_battery)
  if [[ ! "$battery_percent" =~ ^[0-9]+$ ]]; then
    bg_error "Invalid battery percentage: '$battery_percent'. Using previous value: ${previous_battery_percent:-50}"
    battery_percent=${previous_battery_percent:-50}
  fi

  # Get AC status with error checking
  local ac_status
  ac_status=$(bg_check_ac_status)
  if [[ "$ac_status" != "Charging" && "$ac_status" != "Discharging" ]]; then
    bg_warn "Unrecognized AC status: '$ac_status'. Using previous value: ${previous_ac_status:-Discharging}"
    ac_status=${previous_ac_status:-Discharging}
  fi

  # Log current status (only if changed to reduce log size)
  if [ "${battery_percent}" != "${previous_battery_percent:-0}" ] || [ "${ac_status}" != "${previous_ac_status:-Unknown}" ]; then
    bg_info "Battery: $battery_percent%, AC: $ac_status"
  fi

  # Handle AC connection state changes
  if [ "$ac_status" == "Charging" ] && [ "${previous_ac_status:-Unknown}" != "Charging" ]; then
    bg_info "AC power connected."
    bg_send_notification "Battery Info" "AC power connected." "normal"
    # Set brightness to AC level when power is connected
    if [[ -n "${bg_BRIGHTNESS_MAX:-}" ]]; then
      bg_set_brightness "${bg_BRIGHTNESS_MAX}"
    fi
  elif [ "$ac_status" == "Discharging" ] && [ "${previous_ac_status:-Unknown}" == "Charging" ]; then
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

  # Update previous values (use variables from parent scope)
  previous_ac_status="$ac_status"
  previous_battery_percent="$battery_percent"
}

# Monitor battery events using UPower D-Bus signals
bg_monitor_upower_events() {
  bg_info "Starting UPower event monitoring..."

  # Initialize by checking battery once
  check_battery_and_adjust_brightness

  # Use dbus-monitor to listen for UPower events
  if bg_check_command_exists "dbus-monitor"; then
    bg_info "Watching UPower events via D-Bus..."

    # Filter for UPower-related events
    # Use timeout command to handle potential authorization issues
    if timeout "${bg_DBUS_TEST_TIMEOUT:-5}s" dbus-monitor --system "type='signal',interface='org.freedesktop.UPower.Device'" 2>/dev/null | grep -q . ; then
      bg_info "D-Bus monitor connection successful, monitoring events..."
      dbus-monitor --system "type='signal',interface='org.freedesktop.UPower.Device'" | while read -r line; do
        if [[ "$line" == *"Device"*"Changed"* ]]; then
          bg_info "Power event detected via UPower"
          check_battery_and_adjust_brightness
        fi
      done
    else
      bg_warn "D-Bus monitoring failed (possible authorization issue). Falling back to polling."
      # Fall back to polling with adaptive back-off
      local prev_bat_percent=${previous_battery_percent:-0}
      local prev_ac=${previous_ac_status:-"Unknown"}
      local has_changed=1  # Start with 1 to force initial reset of back-off
      
      while true; do
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
        
        # Update previous values for next comparison
        prev_bat_percent=$previous_battery_percent
        prev_ac=$previous_ac_status
        
        bg_info "Sleeping for ${sleep_duration}s (adaptive back-off)"
        sleep $sleep_duration
      done
    fi
  else
    bg_warn "dbus-monitor not available. Falling back to polling."
    # Fall back to polling with adaptive back-off
    local prev_bat_percent=${previous_battery_percent:-0}
    local prev_ac=${previous_ac_status:-"Unknown"}
    local has_changed=1  # Start with 1 to force initial reset of back-off
    
    while true; do
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
      
      # Update previous values for next comparison
      prev_bat_percent=$previous_battery_percent
      prev_ac=$previous_ac_status
      
      bg_info "Sleeping for ${sleep_duration}s (adaptive back-off)"
      sleep $sleep_duration
    done
  fi
}

# Monitor battery events using ACPI events
bg_monitor_acpid_events() {
  bg_info "Starting ACPI event monitoring..."

  # Initialize by checking battery once
  check_battery_and_adjust_brightness

  # Use acpi_listen to monitor power events
  if bg_check_command_exists "acpi_listen"; then
    bg_info "Watching ACPI events..."

    # Listen for battery and AC adapter events
    acpi_listen | while read -r line; do
      if [[ "$line" == *"battery"* ]] || [[ "$line" == *"ac_adapter"* ]]; then
        bg_info "Power event detected via ACPI: $line"
        check_battery_and_adjust_brightness
      fi
    done
  else
    bg_warn "acpi_listen not available. Falling back to inotify monitoring."
    bg_monitor_sysfs_events
  fi
}

# Monitor battery events using inotifywait on sysfs files
bg_monitor_sysfs_events() {
  bg_info "Starting sysfs event monitoring using inotify..."

  # Initialize by checking battery once
  check_battery_and_adjust_brightness

  # Find paths to monitor
  local battery_paths=()
  local ac_paths=()

  # Add known battery paths
  for bat in /sys/class/power_supply/BAT*/; do
    if [[ -d "$bat" ]]; then
      battery_paths+=("$bat")
    fi
  done

  # Add known AC adapter paths
  for ac in /sys/class/power_supply/*/; do
    if [[ -f "${ac}type" ]] && grep -q "Mains" "${ac}type" 2>/dev/null; then
      ac_paths+=("$ac")
    fi
  done

  # Add specific known AC paths
  for ac_name in "AC" "ACAD" "ADP1"; do
    if [[ -d "/sys/class/power_supply/$ac_name" ]]; then
      ac_paths+=("/sys/class/power_supply/$ac_name/")
    fi
  done

  # If we have inotifywait, monitor the directories
  if bg_check_command_exists "inotifywait"; then
    bg_info "Monitoring paths for changes: ${battery_paths[*]} ${ac_paths[*]}"

    # Use adaptive timeout for inotifywait
    local prev_bat_percent=${previous_battery_percent:-0}
    local prev_ac=${previous_ac_status:-"Unknown"}
    local has_changed=1  # Start with 1 to force initial reset of back-off
    
    while true; do
      # Calculate timeout based on adaptive back-off
      local timeout_duration
      timeout_duration=$(bg_get_sleep_duration "$previous_battery_percent" "$previous_ac_status" "$has_changed")
      
      # Monitor all paths with adaptive timeout
      bg_info "Watching power supply changes with ${timeout_duration}s timeout..."
      if inotifywait -e modify -e create -t "$timeout_duration" "${battery_paths[@]}" "${ac_paths[@]}" 2>/dev/null; then
        bg_info "Power state change detected via inotify"
        has_changed=1
      else
        bg_debug "inotifywait timeout reached"
        has_changed=0
      fi
      
      # Check battery status
      check_battery_and_adjust_brightness
      
      # Detect if status changed even without an inotify event
      if [[ "$prev_bat_percent" != "$previous_battery_percent" || "$prev_ac" != "$previous_ac_status" ]]; then
        has_changed=1
      fi
      
      # Update previous values for next comparison
      prev_bat_percent=$previous_battery_percent
      prev_ac=$previous_ac_status
    done
  else
    bg_warn "inotifywait not available. Falling back to polling with adaptive back-off."
    # Fall back to polling with adaptive back-off
    local prev_bat_percent=${previous_battery_percent:-0}
    local prev_ac=${previous_ac_status:-"Unknown"}
    local has_changed=1  # Start with 1 to force initial reset of back-off
    
    while true; do
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
      
      # Update previous values for next comparison
      prev_bat_percent=$previous_battery_percent
      prev_ac=$previous_ac_status
      
      bg_info "Sleeping for ${sleep_duration}s (adaptive back-off)"
      sleep $sleep_duration
    done
  fi
}

# Start monitoring based on available systems with direct polling fallback
# to prevent latency issues when other monitoring methods aren't available
start_monitoring() {
  if pgrep -x "upowerd" >/dev/null; then
    bg_monitor_upower_events
  elif pgrep -x "acpid" >/dev/null; then
    bg_monitor_acpid_events
  else
    bg_warn "Falling back to polling with adaptive back-off"
    # Fall back to polling with adaptive back-off
    local prev_bat_percent=${previous_battery_percent:-0}
    local prev_ac=${previous_ac_status:-"Unknown"}
    local has_changed=1  # Start with 1 to force initial reset of back-off
    
    while true; do
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
      
      # Update previous values for next comparison
      prev_bat_percent=$previous_battery_percent
      prev_ac=$previous_ac_status
      
      bg_info "Sleeping for ${sleep_duration}s (adaptive back-off)"
      sleep $sleep_duration
    done
  fi
}
