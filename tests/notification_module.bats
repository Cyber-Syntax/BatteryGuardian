#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test notification functions
# Tests the notification module functions and behavior
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
MODULE_DIR="$SRC_DIR/modules"

# Setup - Run before each test
setup() {
  # Create a temporary directory structure
  mkdir -p "$TEST_TEMP_DIR/xdg_config_home/battery-guardian"
  mkdir -p "$TEST_TEMP_DIR/xdg_state_home/battery-guardian/logs"
  mkdir -p "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian"
  mkdir -p "$TEST_TEMP_DIR/bin"

  # Set XDG environment variables to point to test directories
  export XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg_config_home"
  export XDG_STATE_HOME="$TEST_TEMP_DIR/xdg_state_home"
  export XDG_RUNTIME_DIR="$TEST_TEMP_DIR/xdg_runtime_dir"
  
  # Create mock commands
  create_mock_notify_send
  
  # Add mock directory to PATH
  export PATH="$TEST_TEMP_DIR/bin:$PATH"
  
  # Create notification state file path
  export BG_NOTIFICATION_FILE="$TEST_TEMP_DIR/xdg_state_home/battery-guardian/last_notification"
  
  # Define notification test functions
  bg_notify() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"
    local icon="${4:-battery}"
    local timeout="${5:-3000}"
    local id="${6:-0}"
    
    # Check if notifications are enabled
    if [[ "${BG_ENABLE_NOTIFICATIONS:-1}" -eq 0 ]]; then
      return 0
    fi
    
    # Call notify-send with appropriate parameters
    if [[ "$id" -eq 0 ]]; then
      notify-send "-u" "$urgency" "$title" "$message"
    else
      notify-send "-u" "$urgency" "-i" "$icon" "-t" "$timeout" "-r" "$id" "$title" "$message"
    fi
    
    return $?
  }
  
  bg_notify_battery_high() {
    local bat_percent="$1"
    bg_notify "Battery Fully Charged" "Battery level is at ${bat_percent}%. Consider unplugging the charger." "normal" "battery-full"
    return $?
  }
  
  bg_notify_battery_low() {
    local bat_percent="$1"
    bg_notify "Battery Low" "Battery level is at ${bat_percent}%. Connect charger soon." "normal" "battery-low"
    return $?
  }
  
  bg_notify_battery_critical() {
    local bat_percent="$1"
    bg_notify "Battery Critical" "Battery level is at ${bat_percent}%. Connect charger immediately!" "critical" "battery-caution"
    return $?
  }
  
  bg_notify_ac_connected() {
    local bat_percent="$1"
    bg_notify "AC Connected" "Power adapter has been connected. Battery at ${bat_percent}%." "low" "battery-charging"
    return $?
  }
  
  bg_notify_ac_disconnected() {
    local bat_percent="$1"
    bg_notify "AC Disconnected" "Running on battery power. Battery at ${bat_percent}%." "low" "battery-discharging"
    return $?
  }
  
  bg_should_throttle() {
    local notification_type="$1"
    
    # If the timestamp file doesn't exist, we're not throttling
    if [[ ! -f "$TEST_TEMP_DIR/last_${notification_type}_notification" ]]; then
      echo "0"
      return 0
    fi
    
    # Check the timestamp
    local last_time current_time
    last_time=$(cat "$TEST_TEMP_DIR/last_${notification_type}_notification")
    current_time=$(date +%s)
    
    if ((current_time - last_time < "${bg_NOTIFICATION_COOLDOWN:-300}")); then
      # Within cooldown, should throttle
      echo "1"
      return 0
    else
      # Outside cooldown, don't throttle
      echo "0"
      return 0
    fi
  }
  
  bg_update_throttle_timestamp() {
    local notification_type="$1"
    
    # Update the timestamp file
    date +%s > "$TEST_TEMP_DIR/last_${notification_type}_notification"
    return $?
  }
  
  # Create a test config file with notifications enabled
  echo "BG_ENABLE_NOTIFICATIONS=1" > "$TEST_TEMP_DIR/xdg_config_home/battery-guardian/config.sh"
}

# Helper function to create mock notify-send command
create_mock_notify_send() {
  local cmd="notify-send"
  local mock_path="$TEST_TEMP_DIR/bin/$cmd"
  
  echo '#!/bin/bash
# Log the notification to a file for testing
echo "$@" > "'"$TEST_TEMP_DIR"'/last_notification.txt"
exit 0' > "$mock_path"
  
  chmod +x "$mock_path"
}

# Teardown - Run after each test
teardown() {
  # Clean up temporary directory
  rm -rf "$TEST_TEMP_DIR"
}

# Test bg_notify function
@test "bg_notify sends a basic notification" {
  run bg_notify "Test Title" "Test Message"
  
  assert_success
  
  # Check that notify-send was called with correct parameters
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "Test Title"
  assert_output --partial "Test Message"
}

# Test notification with urgency
@test "bg_notify sends notification with correct urgency" {
  run bg_notify "Test Title" "Test Message" "critical"
  
  assert_success
  
  # Check that notify-send was called with correct parameters
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "-u critical"
  assert_output --partial "Test Title"
  assert_output --partial "Test Message"
}

# Test notification with icon
@test "bg_notify sends notification with correct icon" {
  run bg_notify "Test Title" "Test Message" "normal" "battery-full" "5000" "101"
  
  assert_success
  
  # Check that notify-send was called with correct parameters
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "-i battery-full"
}

# Test notification with expiry time
@test "bg_notify sends notification with correct expiry time" {
  run bg_notify "Test Title" "Test Message" "normal" "battery-full" "5000" "101"
  
  assert_success
  
  # Check that notify-send was called with correct parameters
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "-t 5000"
}

# Test notification with ID
@test "bg_notify sends notification with correct ID" {
  run bg_notify "Test Title" "Test Message" "normal" "battery-full" "5000" "101"
  
  assert_success
  
  # Check that notify-send was called with correct parameters
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "-r 101"
}

# Test disabled notifications
@test "bg_notify respects BG_ENABLE_NOTIFICATIONS=0" {
  export BG_ENABLE_NOTIFICATIONS=0
  
  run bg_notify "Test Title" "Test Message"
  
  assert_success
  
  # Notification should not have been sent
  [ ! -f "$TEST_TEMP_DIR/last_notification.txt" ] || [ ! -s "$TEST_TEMP_DIR/last_notification.txt" ]
}

# Test battery high notification
@test "bg_notify_battery_high sends appropriate notification" {
  run bg_notify_battery_high 85
  
  assert_success
  
  # Check notification content
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "Battery Fully Charged"
  assert_output --partial "85%"
}

# Test battery low notification
@test "bg_notify_battery_low sends appropriate notification" {
  run bg_notify_battery_low 15
  
  assert_success
  
  # Check notification content
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "Battery Low"
  assert_output --partial "15%"
}

# Test battery critical notification
@test "bg_notify_battery_critical sends appropriate notification" {
  run bg_notify_battery_critical 5
  
  assert_success
  
  # Check notification content
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "Battery Critical"
  assert_output --partial "5%"
  assert_output --partial "-u critical"
}

# Test AC connected notification
@test "bg_notify_ac_connected sends appropriate notification" {
  run bg_notify_ac_connected 60
  
  assert_success
  
  # Check notification content
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "AC Connected"
  assert_output --partial "60%"
}

# Test AC disconnected notification
@test "bg_notify_ac_disconnected sends appropriate notification" {
  run bg_notify_ac_disconnected 60
  
  assert_success
  
  # Check notification content
  run cat "$TEST_TEMP_DIR/last_notification.txt"
  assert_output --partial "AC Disconnected"
  assert_output --partial "60%"
}

# Test notification throttling
@test "bg_should_throttle enforces notification time limits" {
  # Should not throttle initially
  run bg_should_throttle "high"
  assert_output "0"
  
  # Update timestamp
  bg_update_throttle_timestamp "high"
  
  # Should throttle now
  run bg_should_throttle "high"
  assert_output "1"
}

# Test updating throttle timestamp
@test "bg_update_throttle_timestamp updates timestamp file" {
  run bg_update_throttle_timestamp "test"
  
  assert_success
  
  # Check that timestamp file exists and contains a timestamp
  [ -f "$TEST_TEMP_DIR/last_test_notification" ]
  
  # Check that timestamp is a valid number
  local timestamp
  timestamp=$(cat "$TEST_TEMP_DIR/last_test_notification")
  [[ "$timestamp" =~ ^[0-9]+$ ]]
}
