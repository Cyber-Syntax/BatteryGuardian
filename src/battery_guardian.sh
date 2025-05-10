#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - Battery monitoring and management tool
# Monitors laptop battery status and takes actions to extend battery life
# Author: Cyber-Syntax
# License: BSD 3-Clause License
# --------------------------------------------------------

# Ensure script exits on errors and undefined variables
set -o errexit -o nounset -o pipefail

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
BG_MAX_LOG_SIZE=1048576  # 1MB in bytes
BG_MAX_LOG_COUNT=3       # Keep 3 rotated log files

# Create necessary directories
mkdir -p "${BG_CONFIG_DIR}" 2>/dev/null || true
mkdir -p "${BG_STATE_DIR}/logs" 2>/dev/null || true
mkdir -p "${BG_RUNTIME_DIR}" 2>/dev/null || {
    # Fallback to /tmp if XDG_RUNTIME_DIR can't be used
    BG_RUNTIME_DIR="/tmp/battery-guardian"
    mkdir -p "${BG_RUNTIME_DIR}" 2>/dev/null || true
}

# ---- Configuration Files ----
BG_DEFAULT_CONFIG="$(dirname "$(dirname "$(readlink -f "$0")")")/configs/defaults.sh"
BG_USER_CONFIG="${BG_CONFIG_DIR}/config.sh"

# ---- Runtime Files ----
BG_LOG_FILE="${BG_STATE_DIR}/logs/battery.log"
BG_LOCK_FILE="${BG_RUNTIME_DIR}/battery_monitor.lock"
BG_NOTIFICATION_FILE="${BG_RUNTIME_DIR}/last_notification"

# ---- Cached Paths ----
bg_BATTERY_PATH=""  # Will be populated when a working battery path is found
bg_AC_PATH="" # Will be populated when a working AC path is found

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
        log_size=$(wc -c < "$BG_LOG_FILE" 2>/dev/null) || {
            # Cannot check size - may be permissions or non-existent file
            return 1
        }
    fi

    # If log file is smaller than max size, no rotation needed
    if [[ "$log_size" -lt "$BG_MAX_LOG_SIZE" ]]; then
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
    for ((i=BG_MAX_LOG_COUNT-1; i>0; i--)); do
        local j=$((i+1))
        if [[ -f "${full_path}.$i" ]]; then
            mv "${full_path}.$i" "${full_path}.$j" 2>/dev/null ||
                echo "WARNING: Failed to rotate log from ${full_path}.$i to ${full_path}.$j" >&2
        fi
    done

    # Move the current log to .1
    mv "$full_path" "${full_path}.1" 2>/dev/null || {
        echo "WARNING: Failed to rotate current log to ${full_path}.1" >&2
        # If we can't rotate, try to clear the current log instead
        : > "$full_path" 2>/dev/null ||
            echo "ERROR: Failed to clear current log. Log entries may be lost." >&2
    }

    return 0
}

# ---- Logging Function ----
# Log messages with timestamps
bg_log() {
    local level="$1"
    local message="$2"
    local datetime
    datetime=$(date +'%Y-%m-%d %H:%M:%S')

    # Create log directory if it doesn't exist yet
    mkdir -p "$(dirname "$BG_LOG_FILE")" 2>/dev/null || {
        BG_LOG_FILE="/tmp/battery-guardian.log"
        echo "WARNING: Could not create log directory, using fallback log file: $BG_LOG_FILE" >&2
    }

    # Rotate logs if necessary before writing
    bg_rotate_logs

    # Write log entry
    echo "[$datetime] [$level] $message" >> "$BG_LOG_FILE"

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

# ---- Check Dependencies ----
bg_check_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

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

    return $missing_deps
}

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
    cat > "$BG_USER_CONFIG" << EOF
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
    echo $$ > "$BG_LOCK_FILE" || {
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
        [ "$bg_BRIGHTNESS_VERY_LOW" -le "$bg_BRIGHTNESS_CRITICAL" ] && bg_BRIGHTNESS_VERY_LOW=$(( bg_BRIGHTNESS_CRITICAL + 5 ))
        [ "$bg_BRIGHTNESS_LOW" -le "$bg_BRIGHTNESS_VERY_LOW" ] && bg_BRIGHTNESS_LOW=$(( bg_BRIGHTNESS_VERY_LOW + 5 ))
        [ "$bg_BRIGHTNESS_MEDIUM_LOW" -le "$bg_BRIGHTNESS_LOW" ] && bg_BRIGHTNESS_MEDIUM_LOW=$(( bg_BRIGHTNESS_LOW + 5 ))
        [ "$bg_BRIGHTNESS_MEDIUM" -le "$bg_BRIGHTNESS_MEDIUM_LOW" ] && bg_BRIGHTNESS_MEDIUM=$(( bg_BRIGHTNESS_MEDIUM_LOW + 5 ))
        [ "$bg_BRIGHTNESS_MEDIUM_HIGH" -le "$bg_BRIGHTNESS_MEDIUM" ] && bg_BRIGHTNESS_MEDIUM_HIGH=$(( bg_BRIGHTNESS_MEDIUM + 5 ))
        [ "$bg_BRIGHTNESS_HIGH" -le "$bg_BRIGHTNESS_MEDIUM_HIGH" ] && bg_BRIGHTNESS_HIGH=$(( bg_BRIGHTNESS_MEDIUM_HIGH + 5 ))
        [ "$bg_BRIGHTNESS_VERY_HIGH" -le "$bg_BRIGHTNESS_HIGH" ] && bg_BRIGHTNESS_VERY_HIGH=$(( bg_BRIGHTNESS_HIGH + 5 ))
        [ "$bg_BRIGHTNESS_MAX" -le "$bg_BRIGHTNESS_VERY_HIGH" ] && bg_BRIGHTNESS_MAX=$(( bg_BRIGHTNESS_VERY_HIGH + 5 ))

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
    echo "50"  # Return a safe default value
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
                "Charging"|"Full") status="Charging" ;;
                "Discharging"|"Not charging") status="Discharging" ;;
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

# ---- Brightness Control Functions ----
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
                brightness=$(( (brightnessctl_output * 100) / max_brightness ))
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
                    brightness=$(( (current * 100) / max ))
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

bg_set_brightness() {
    local brightness_percent=$1
    local success=false

    # Validate input and enforce safety limits (never below 5%)
    if [[ ! "$brightness_percent" =~ ^[0-9]+$ ]] || [ "$brightness_percent" -lt 5 ] || [ "$brightness_percent" -gt 100 ]; then
        bg_warn "Invalid brightness value ($brightness_percent). Using 20% as safety default."
        brightness_percent=20
    fi

    bg_info "Setting brightness to $brightness_percent%"

    # Try using brightnessctl if available
    if bg_check_command_exists "brightnessctl"; then
        brightnessctl s "$brightness_percent%" -q 2>/dev/null
        if [[ $? -eq 0 ]]; then
            bg_info "Successfully set brightness to $brightness_percent% using brightnessctl"
            success=true
            return 0
        fi
        bg_warn "Failed to set brightness using brightnessctl."
    fi

    # Try using light if available
    if bg_check_command_exists "light"; then
        light -S "$brightness_percent" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            bg_info "Successfully set brightness to $brightness_percent% using light"
            success=true
            return 0
        fi
        bg_warn "Failed to set brightness using light."
    fi

    # Try using xbacklight if available (X11 only)
    if bg_check_command_exists "xbacklight"; then
        xbacklight -set "$brightness_percent" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            bg_info "Successfully set brightness to $brightness_percent% using xbacklight"
            success=true
            return 0
        fi
        bg_warn "Failed to set brightness using xbacklight."
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
                        bg_info "Successfully set brightness to $brightness_percent% using sysfs ($backlight_dir)"
                        success=true
                        return 0
                    fi
                fi
            fi
        fi
    done

    if ! $success; then
        bg_error "Failed to set brightness using any available method."
        return 1
    fi
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
    echo "${notification_type}:$(date +%s)" > "$BG_NOTIFICATION_FILE"
}

# ---- Sleep Duration Function ----
bg_get_sleep_duration() {
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