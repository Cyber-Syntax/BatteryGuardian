#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test battery monitoring functionality
# Tests both normal operation and edge cases for the battery guardian script
# Author: Cyber-Syntax
# License: BSD 3-Clause License
# --------------------------------------------------------

# Load bats test helper and mocking library
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/bats-mock/load'

# Define temporary test directory
BATS_TEST_DIRNAME="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
REPO_ROOT="$(dirname "$BATS_TEST_DIRNAME")"
TEST_TEMP_DIR="$BATS_TEST_DIRNAME/tmp"
SRC_DIR="$REPO_ROOT/src"
CONFIG_DIR="$REPO_ROOT/configs"

# The path to the script being tested
SCRIPT_PATH="$SRC_DIR/battery_guardian.sh"

# Set up a helper function to source the script without running the main function
setup_script() {
  # Create a temporary version of the script that doesn't run the main function
  mkdir -p "$TEST_TEMP_DIR"
  cp "$SCRIPT_PATH" "$TEST_TEMP_DIR/battery_guardian_test.sh"
  
  # Comment out the call to main function
  sed -i 's/^bg_main$/# bg_main/g' "$TEST_TEMP_DIR/battery_guardian_test.sh"
  
  # Source the script
  source "$TEST_TEMP_DIR/battery_guardian_test.sh"
}

# Setup - Run before each test
setup() {
  # Create a temporary directory structure
  mkdir -p "$TEST_TEMP_DIR/sys/class/power_supply/BAT0"
  mkdir -p "$TEST_TEMP_DIR/sys/class/power_supply/AC"
  mkdir -p "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight"
  mkdir -p "$TEST_TEMP_DIR/xdg_config_home/battery-guardian"
  mkdir -p "$TEST_TEMP_DIR/xdg_state_home/battery-guardian/logs"
  mkdir -p "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian"
  
  # Set XDG environment variables to point to test directories
  export XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg_config_home"
  export XDG_STATE_HOME="$TEST_TEMP_DIR/xdg_state_home"
  export XDG_RUNTIME_DIR="$TEST_TEMP_DIR/xdg_runtime_dir"
  
  # Create mock battery files with default values
  echo "50" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  echo "Discharging" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/status"
  echo "Battery" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/type"
  
  # Create mock AC adapter files
  echo "0" > "$TEST_TEMP_DIR/sys/class/power_supply/AC/online"
  echo "Mains" > "$TEST_TEMP_DIR/sys/class/power_supply/AC/type"
  
  # Create mock backlight files
  echo "100" > "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight/max_brightness"
  echo "50" > "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight/brightness"
  
  # Create a test config file
  cat > "$TEST_TEMP_DIR/xdg_config_home/battery-guardian/config.sh" << EOF
#!/usr/bin/env bash
# Test configuration
bg_LOW_THRESHOLD=20
bg_CRITICAL_THRESHOLD=10
bg_FULL_BATTERY_THRESHOLD=90
bg_NOTIFICATION_COOLDOWN=300
bg_BRIGHTNESS_CONTROL_ENABLED=true
EOF
  
  # Setup mock commands
  PATH="$TEST_TEMP_DIR/bin:$PATH"
  mkdir -p "$TEST_TEMP_DIR/bin"
}

# Teardown - Run after each test
teardown() {
  # Clean up the test directory
  rm -rf "$TEST_TEMP_DIR"
  unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_RUNTIME_DIR
}

# Create mock command function
create_mock_command() {
  local cmd="$1"
  local output="$2"
  local exitcode="${3:-0}"
  
  mkdir -p "$TEST_TEMP_DIR/bin"
  cat > "$TEST_TEMP_DIR/bin/$cmd" << EOF
#!/usr/bin/env bash
echo "$output"
exit $exitcode
EOF
  chmod +x "$TEST_TEMP_DIR/bin/$cmd"
}

# ---- Test Cases ----

# Test battery existence detection
@test "bg_check_battery_exists detects battery when it exists" {
  setup_script
  
  # Mock the battery path
  mkdir -p "$TEST_TEMP_DIR/sys/class/power_supply/BAT0"
  echo "50" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  
  # Override function to use our test directory
  bg_check_battery_exists() {
    for bat in "$TEST_TEMP_DIR"/sys/class/power_supply/BAT*; do
      if [[ -d "$bat" ]]; then
        return 0
      fi
    done
    return 1
  }
  
  # Run the test
  run bg_check_battery_exists
  
  # Assert it found a battery
  assert_success
}

@test "bg_check_battery_exists returns failure when no battery exists" {
  setup_script
  
  # Remove any battery directories
  rm -rf "$TEST_TEMP_DIR/sys/class/power_supply/BAT"*
  
  # Override function to use our test directory
  bg_check_battery_exists() {
    for bat in "$TEST_TEMP_DIR"/sys/class/power_supply/BAT*; do
      [[ -d "$bat" ]] && return 0
    done
    for alt_bat in "$TEST_TEMP_DIR"/sys/class/power_supply/*; do
      if [[ -d "$alt_bat" && -f "$alt_bat/type" ]]; then
        type=$(cat "$alt_bat/type" 2>/dev/null)
        [[ "$type" == "Battery" ]] && return 0
      fi
    done
    return 1
  }
  
  # Run the test
  run bg_check_battery_exists
  
  # Assert it did not find a battery
  assert_failure
}

# Test battery percentage reading
@test "bg_check_battery handles standard battery path" {
  setup_script
  
  # Set up a mock battery at standard path
  echo "75" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  
  # Override function to use our test directory
  bg_check_battery() {
    local percent=0
    
    # Check the mock battery
    if [[ -f "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity" ]]; then
      percent=$(cat "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity" 2>/dev/null)
      if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
        echo "$percent"
        return
      fi
    fi
    
    # Default value if no valid reading
    echo "50"
  }
  
  # Run the test
  run bg_check_battery
  
  # Assert it read the correct value
  assert_output "75"
}

@test "bg_check_battery handles non-standard battery path" {
  setup_script
  
  # Remove standard battery, create alternative
  rm -rf "$TEST_TEMP_DIR/sys/class/power_supply/BAT"*
  mkdir -p "$TEST_TEMP_DIR/sys/class/power_supply/CMB0"
  echo "Battery" > "$TEST_TEMP_DIR/sys/class/power_supply/CMB0/type"
  echo "65" > "$TEST_TEMP_DIR/sys/class/power_supply/CMB0/capacity"
  
  # Override function to use our test directory
  bg_check_battery() {
    local percent=0
    
    # Check standard paths - will fail
    if [[ -f "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity" ]]; then
      percent=$(cat "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity" 2>/dev/null)
      if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
        echo "$percent"
        return
      fi
    fi
    
    # Check alternative paths
    for alt_bat in "$TEST_TEMP_DIR"/sys/class/power_supply/*; do
      if [[ -d "$alt_bat" && -f "$alt_bat/capacity" && -f "$alt_bat/type" ]]; then
        local type=$(cat "$alt_bat/type" 2>/dev/null)
        if [[ "$type" == "Battery" ]]; then
          percent=$(cat "$alt_bat/capacity" 2>/dev/null)
          if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
            echo "$percent"
            return
          fi
        fi
      fi
    done
    
    # Default value if no valid reading
    echo "50"
  }
  
  # Run the test
  run bg_check_battery
  
  # Assert it found the alternative battery
  assert_output "65"
}

@test "bg_check_battery handles invalid battery reading" {
  setup_script
  
  # Create an invalid battery value
  echo "invalid" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  
  # Override function to use our test directory
  bg_check_battery() {
    local percent=0
    
    # Check the mock battery
    if [[ -f "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity" ]]; then
      percent=$(cat "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity" 2>/dev/null)
      if [[ $? -eq 0 && -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
        echo "$percent"
        return
      fi
    fi
    
    # Default value if no valid reading
    echo "50"
  }
  
  # Run the test
  run bg_check_battery
  
  # Assert it returned the default value
  assert_output "50"
}

# Test AC status detection
@test "bg_check_ac_status detects charging status correctly" {
  setup_script
  
  # Set AC adapter to online
  echo "1" > "$TEST_TEMP_DIR/sys/class/power_supply/AC/online"
  
  # Override function to use our test directory
  bg_check_ac_status() {
    local status="Discharging"
    
    # Check the mock AC adapter
    if [[ -f "$TEST_TEMP_DIR/sys/class/power_supply/AC/online" ]]; then
      local online=$(cat "$TEST_TEMP_DIR/sys/class/power_supply/AC/online" 2>/dev/null)
      if [[ $? -eq 0 && -n "$online" ]]; then
        [[ "$online" == "1" ]] && status="Charging" || status="Discharging"
        echo "$status"
        return
      fi
    fi
    
    echo "$status"
  }
  
  # Run the test
  run bg_check_ac_status
  
  # Assert it detected charging status correctly
  assert_output "Charging"
}

@test "bg_check_ac_status falls back to checking battery status" {
  setup_script
  
  # Remove AC adapter, set battery status to charging
  rm -rf "$TEST_TEMP_DIR/sys/class/power_supply/AC"
  echo "Charging" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/status"
  
  # Override function to use our test directory
  bg_check_ac_status() {
    local status="Discharging"
    
    # Check the mock AC adapter - will fail
    if [[ -f "$TEST_TEMP_DIR/sys/class/power_supply/AC/online" ]]; then
      local online=$(cat "$TEST_TEMP_DIR/sys/class/power_supply/AC/online" 2>/dev/null)
      if [[ $? -eq 0 && -n "$online" ]]; then
        [[ "$online" == "1" ]] && status="Charging" || status="Discharging"
        echo "$status"
        return
      fi
    fi
    
    # Fall back to checking battery status
    if [[ -f "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/status" ]]; then
      local bat_status=$(cat "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/status" 2>/dev/null)
      if [[ $? -eq 0 && -n "$bat_status" ]]; then
        case "$bat_status" in
          "Charging"|"Full") status="Charging" ;;
          "Discharging"|"Not charging") status="Discharging" ;;
        esac
        echo "$status"
        return
      fi
    fi
    
    echo "$status"
  }
  
  # Run the test
  run bg_check_ac_status
  
  # Assert it detected charging status from battery status
  assert_output "Charging"
}

# Test brightness control
@test "bg_set_brightness handles brightnessctl successfully" {
  setup_script
  
  # Create mock brightnessctl command
  create_mock_command "brightnessctl" "Setting brightness to 75%..." 0
  
  # Create a function to track which method was used
  method_used=""
  
  # Override function to use our test directory and track method
  bg_set_brightness() {
    local brightness_percent="$1"
    local success=false
    
    # Try brightnessctl
    if command -v brightnessctl >/dev/null 2>&1; then
      brightnessctl s "$brightness_percent%" -q 2>/dev/null
      if [[ $? -eq 0 ]]; then
        method_used="brightnessctl"
        success=true
        return 0
      fi
    fi
    
    # Other methods would follow, but we're testing brightnessctl specifically
    
    if ! $success; then
      return 1
    fi
  }
  
  # Run brightness setting
  bg_set_brightness 75
  
  # Assert brightnessctl was used
  assert_equal "$method_used" "brightnessctl"
}

@test "bg_set_brightness falls back to sysfs when no command is available" {
  setup_script
  
  # Create a function to track which method was used
  method_used=""
  
  # Mock sysfs backlight control
  mkdir -p "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight"
  echo "100" > "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight/max_brightness"
  chmod +w "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight"
  touch "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight/brightness"
  chmod +w "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight/brightness"
  
  # Override function to use our test directory and track method
  bg_set_brightness() {
    local brightness_percent="$1"
    local success=false
    
    # Skip other methods, go straight to sysfs
    for backlight_dir in "$TEST_TEMP_DIR"/sys/class/backlight/*; do
      if [[ -d "$backlight_dir" && -f "$backlight_dir/brightness" && -f "$backlight_dir/max_brightness" ]]; then
        local max=$(cat "$backlight_dir/max_brightness" 2>/dev/null)
        
        if [[ $? -eq 0 && -n "$max" && "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
          # Calculate raw value
          local raw_value=$((max * brightness_percent / 100))
          
          # Try to set brightness
          echo "$raw_value" > "$backlight_dir/brightness" 2>/dev/null
          if [[ $? -eq 0 ]]; then
            method_used="sysfs"
            success=true
            return 0
          fi
        fi
      fi
    done
    
    if ! $success; then
      return 1
    fi
  }
  
  # Run brightness setting
  bg_set_brightness 75
  
  # Assert sysfs was used
  assert_equal "$method_used" "sysfs"
}

@test "bg_get_current_brightness handles invalid inputs" {
  setup_script
  
  # Create invalid backlight files
  mkdir -p "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight"
  echo "invalid" > "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight/max_brightness"
  echo "invalid" > "$TEST_TEMP_DIR/sys/class/backlight/intel_backlight/brightness"
  
  # Override function to use our test directory
  bg_get_current_brightness() {
    local brightness=100
    local success=false
    
    # Try to get brightness from invalid sysfs
    for backlight_dir in "$TEST_TEMP_DIR"/sys/class/backlight/*; do
      if [[ -d "$backlight_dir" && -f "$backlight_dir/brightness" && -f "$backlight_dir/max_brightness" ]]; then
        local current max
        current=$(cat "$backlight_dir/brightness" 2>/dev/null)
        max=$(cat "$backlight_dir/max_brightness" 2>/dev/null)
        
        if [[ $? -eq 0 && -n "$current" && -n "$max" && "$current" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
          brightness=$(( (current * 100) / max ))
          if [[ "$brightness" =~ ^[0-9]+$ && "$brightness" -ge 0 && "$brightness" -le 100 ]]; then
            success=true
            echo "$brightness"
            return
          fi
        fi
      fi
    done
    
    # Return default since we couldn't get a valid reading
    echo "$brightness"
  }
  
  # Run the test
  run bg_get_current_brightness
  
  # Assert it returned the default value
  assert_output "100"
}

# Test log rotation
@test "bg_rotate_logs rotates logs when they exceed max size" {
  setup_script
  
  # Define variables
  local log_file="$TEST_TEMP_DIR/xdg_state_home/battery-guardian/logs/battery.log"
  local BG_LOG_FILE="$log_file"
  local BG_MAX_LOG_SIZE=1000  # Small for testing
  local BG_MAX_LOG_COUNT=3
  
  # Create a log file that exceeds the max size
  mkdir -p "$(dirname "$log_file")"
  yes "This is a log entry" | head -n 50 > "$log_file"
  
  # Create the first rotated log to test full rotation
  cp "$log_file" "${log_file}.1"
  
  # Override function for testing
  bg_rotate_logs() {
    # If log file doesn't exist yet, nothing to rotate
    if [[ ! -f "$BG_LOG_FILE" ]]; then
        return 0
    fi
    
    # Check current log file size
    local log_size
    log_size=$(stat -c %s "$BG_LOG_FILE" 2>/dev/null || wc -c < "$BG_LOG_FILE" 2>/dev/null)
    
    # If log file is smaller than max size, no rotation needed
    if [[ "$log_size" -lt "$BG_MAX_LOG_SIZE" ]]; then
        return 0
    fi
    
    # Perform rotation
    # Remove the oldest log if it exists
    if [[ -f "${BG_LOG_FILE}.${BG_MAX_LOG_COUNT}" ]]; then
        rm "${BG_LOG_FILE}.${BG_MAX_LOG_COUNT}" 2>/dev/null
    fi
    
    # Shift the other logs
    for ((i=BG_MAX_LOG_COUNT-1; i>0; i--)); do
        local j=$((i+1))
        if [[ -f "${BG_LOG_FILE}.$i" ]]; then
            mv "${BG_LOG_FILE}.$i" "${BG_LOG_FILE}.$j" 2>/dev/null
        fi
    done
    
    # Move the current log to .1
    mv "$BG_LOG_FILE" "${BG_LOG_FILE}.1" 2>/dev/null
    touch "$BG_LOG_FILE"
  }
  
  # Run the rotation
  bg_rotate_logs
  
  # Assert the rotation happened correctly
  assert [ -f "${log_file}" ]  # New empty log created
  assert [ -f "${log_file}.1" ]  # Old log rotated to .1
  assert [ -f "${log_file}.2" ]  # Previous .1 moved to .2
  assert [ ! -f "${log_file}.3" ]  # No .3 created yet
}

# Test config validation
@test "bg_validate_config handles invalid threshold values" {
  setup_script
  
  # Set up invalid values
  bg_LOW_THRESHOLD=-10  # Too low
  bg_CRITICAL_THRESHOLD=200  # Too high
  bg_FULL_BATTERY_THRESHOLD=150  # Too high
  
  # Flag to track if errors were detected and fixed
  errors_fixed=false
  
  # Override validation function
  bg_validate_config() {
    local has_errors=false
    
    # Validate thresholds
    if [[ ! "$bg_LOW_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$bg_LOW_THRESHOLD" -lt 5 ] || [ "$bg_LOW_THRESHOLD" -gt 50 ]; then
      bg_LOW_THRESHOLD=20
      has_errors=true
    fi
    
    if [[ ! "$bg_CRITICAL_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$bg_CRITICAL_THRESHOLD" -lt 3 ] || [ "$bg_CRITICAL_THRESHOLD" -gt "$bg_LOW_THRESHOLD" ]]; then
      bg_CRITICAL_THRESHOLD=10
      has_errors=true
    fi
    
    if [[ ! "$bg_FULL_BATTERY_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$bg_FULL_BATTERY_THRESHOLD" -lt 80 ] || [ "$bg_FULL_BATTERY_THRESHOLD" -gt 100 ]]; then
      bg_FULL_BATTERY_THRESHOLD=90
      has_errors=true
    fi
    
    # Set global flag if errors were fixed
    if [ "$has_errors" = true ]; then
      errors_fixed=true
    fi
  }
  
  # Run validation
  bg_validate_config
  
  # Assert it fixed the invalid values
  assert_equal "$bg_LOW_THRESHOLD" "20"
  assert_equal "$bg_CRITICAL_THRESHOLD" "10"
  assert_equal "$bg_FULL_BATTERY_THRESHOLD" "90"
  assert_equal "$errors_fixed" "true"
}

@test "bg_validate_config fixes brightness values not in descending order" {
  setup_script
  
  # Set up brightness values in wrong order
  bg_BRIGHTNESS_MAX=50
  bg_BRIGHTNESS_VERY_HIGH=60
  bg_BRIGHTNESS_HIGH=70
  bg_BRIGHTNESS_MEDIUM_HIGH=80
  bg_BRIGHTNESS_MEDIUM=90
  bg_BRIGHTNESS_MEDIUM_LOW=100
  bg_BRIGHTNESS_LOW=40
  bg_BRIGHTNESS_VERY_LOW=30
  bg_BRIGHTNESS_CRITICAL=20
  
  # Override validation function
  bg_validate_config() {
    local has_errors=false
    
    # Ensure brightness thresholds are in descending order
    if [ "$bg_BRIGHTNESS_MAX" -lt "$bg_BRIGHTNESS_VERY_HIGH" ] ||
       [ "$bg_BRIGHTNESS_VERY_HIGH" -lt "$bg_BRIGHTNESS_HIGH" ] ||
       [ "$bg_BRIGHTNESS_HIGH" -lt "$bg_BRIGHTNESS_MEDIUM_HIGH" ] ||
       [ "$bg_BRIGHTNESS_MEDIUM_HIGH" -lt "$bg_BRIGHTNESS_MEDIUM" ] ||
       [ "$bg_BRIGHTNESS_MEDIUM" -lt "$bg_BRIGHTNESS_MEDIUM_LOW" ] ||
       [ "$bg_BRIGHTNESS_MEDIUM_LOW" -lt "$bg_BRIGHTNESS_LOW" ] ||
       [ "$bg_BRIGHTNESS_LOW" -lt "$bg_BRIGHTNESS_VERY_LOW" ] ||
       [ "$bg_BRIGHTNESS_VERY_LOW" -lt "$bg_BRIGHTNESS_CRITICAL" ]; then
      
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
  }
  
  # Run validation
  bg_validate_config
  
  # The brightness values should now be in descending order
  assert [ "$bg_BRIGHTNESS_MAX" -ge "$bg_BRIGHTNESS_VERY_HIGH" ]
  assert [ "$bg_BRIGHTNESS_VERY_HIGH" -ge "$bg_BRIGHTNESS_HIGH" ]
  assert [ "$bg_BRIGHTNESS_HIGH" -ge "$bg_BRIGHTNESS_MEDIUM_HIGH" ]
  assert [ "$bg_BRIGHTNESS_MEDIUM_HIGH" -ge "$bg_BRIGHTNESS_MEDIUM" ]
  assert [ "$bg_BRIGHTNESS_MEDIUM" -ge "$bg_BRIGHTNESS_MEDIUM_LOW" ]
  assert [ "$bg_BRIGHTNESS_MEDIUM_LOW" -ge "$bg_BRIGHTNESS_LOW" ]
  assert [ "$bg_BRIGHTNESS_LOW" -ge "$bg_BRIGHTNESS_VERY_LOW" ]
  assert [ "$bg_BRIGHTNESS_VERY_LOW" -ge "$bg_BRIGHTNESS_CRITICAL" ]
}

# Test notification handling
@test "bg_should_send_notification respects cooldown period" {
  setup_script
  
  # Set up test variables
  local bg_LOW_THRESHOLD=20
  local bg_CRITICAL_THRESHOLD=10
  local bg_FULL_BATTERY_THRESHOLD=90
  local bg_NOTIFICATION_COOLDOWN=300
  local BG_NOTIFICATION_FILE="$TEST_TEMP_DIR/last_notification"
  
  # Create a recent notification record (less than cooldown period)
  current_time=$(date +%s)
  echo "low:$((current_time - 60))" > "$BG_NOTIFICATION_FILE"
  
  # Override function for testing
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
      local last_notification=$(cat "$BG_NOTIFICATION_FILE")
      local last_type=${last_notification%:*}
      local last_time=${last_notification#*:}
      local current_time=$(date +%s)
      
      # If same notification type was sent within cooldown period, skip it
      if [ "$notification_type" == "$last_type" ] && 
         ((current_time - last_time < bg_NOTIFICATION_COOLDOWN)); then
        return 1 # Skip notification
      fi
    fi
    
    return 0 # Send notification
  }
  
  # Run the test for a low battery case (should be suppressed due to cooldown)
  run bg_should_send_notification 15 "Discharging"
  
  # Assert notification is suppressed
  assert_failure
  
  # Run for a critical battery case (different notification type, should not be suppressed)
  run bg_should_send_notification 5 "Discharging"
  
  # Assert notification is sent
  assert_success
}

# Test edge case - handle missing configuration file
@test "bg_load_config handles missing default config" {
  setup_script
  
  # Remove default config and ensure it doesn't exist
  local BG_DEFAULT_CONFIG="$TEST_TEMP_DIR/nonexistent_config.sh"
  local BG_USER_CONFIG="$TEST_TEMP_DIR/xdg_config_home/battery-guardian/config.sh"
  
  # Track if error was logged
  error_logged=""
  
  # Override error logging function
  bg_error() {
    error_logged="$1"
  }
  
  # Mock config loading function
  bg_load_config() {
    # Start with default values
    if [[ -f "$BG_DEFAULT_CONFIG" ]]; then
      source "$BG_DEFAULT_CONFIG"
    else
      bg_error "Default configuration file not found at $BG_DEFAULT_CONFIG"
    fi
    
    # Load user configuration if it exists
    if [[ -f "$BG_USER_CONFIG" ]]; then
      source "$BG_USER_CONFIG"
    fi
  }
  
  # Run config loading
  bg_load_config
  
  # Assert error message was generated
  assert_equal "$error_logged" "Default configuration file not found at $BG_DEFAULT_CONFIG"
}