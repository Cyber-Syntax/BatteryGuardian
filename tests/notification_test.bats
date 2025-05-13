#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test for notification module
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
  
  # Source the required modules
  source "$MODULE_DIR/log.sh"
  source "$MODULE_DIR/utils.sh"
  source "$MODULE_DIR/notification.sh"
  
  # Create a test config file with notifications enabled
  echo "BG_ENABLE_NOTIFICATIONS=1" > "$TEST_TEMP_DIR/xdg_config_home/battery-guardian/config.sh"
}

# Helper function to create mock notify-send command
create_mock_notify_send() {
  local cmd="notify-send"
  local mock_path="$TEST_TEMP_DIR/bin/$cmd"
  
  echo '#!/bin/bash
# Log the notification to a file for testing
echo "NOTIFICATION: $*" >> "$XDG_RUNTIME_DIR/battery-guardian/notifications.log"
exit 0
' > "$mock_path"
  
  chmod +x "$mock_path"
}

# Teardown - Run after each test
teardown() {
  # Clean up temporary directory
  rm -rf "$TEST_TEMP_DIR"
}

# Test for basic notification functionality
@test "bg_send_notification sends notification with the correct parameters" {
  run bg_send_notification "Test Title" "Test Message" "normal"
  
  assert_success
  
  # Check the notification log
  run cat "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/notifications.log"
  
  assert_success
  assert_output --partial "Test Title"
  assert_output --partial "Test Message"
}

# Test notification with urgency levels
@test "bg_send_notification respects urgency levels" {
  run bg_send_notification "Critical" "This is critical" "critical"
  
  assert_success
  
  # Check the notification log
  run cat "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/notifications.log"
  
  assert_success
  assert_output --partial "Critical"
  assert_output --partial "-u critical"
}

# Test for notification suppression when disabled
@test "bg_send_notification does nothing when notifications are disabled" {
  # Disable notifications by setting the environment variable directly
  export BG_ENABLE_NOTIFICATIONS=0
  
  # Create log file to ensure it exists for the test
  touch "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/notifications.log"
  
  # Run the notification function
  run bg_send_notification "Should Not Show" "This should not appear" "normal"
  
  assert_success
  
  # Check notification log to ensure no notification was added
  run cat "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/notifications.log"
  refute_output --partial "Should Not Show"
}

# Test notification cooldown functionality
@test "bg_send_notification respects cooldown periods" {
  # Set a cooldown period
  echo "BG_NOTIFICATION_COOLDOWN=60" > "$TEST_TEMP_DIR/xdg_config_home/battery-guardian/config.sh"
  
  # Send first notification
  run bg_send_notification "First" "First notification" "normal" "test_type"
  
  assert_success
  
  # Send second notification of same type (should be skipped due to cooldown)
  run bg_send_notification "Second" "Second notification" "normal" "test_type"
  
  assert_success
  
  # Check the notification log
  run cat "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/notifications.log"
  
  assert_success
  assert_output --partial "First"
  refute_output --partial "Second"
}

# Test battery notification function
@test "bg_send_battery_notification sends appropriate message based on battery level" {
  run bg_send_battery_notification "15" "Discharging"
  
  assert_success
  
  # Check the notification log
  run cat "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/notifications.log"
  
  assert_success
  assert_output --partial "Low Battery"
}

# Test critical battery notification
@test "bg_send_battery_notification sends critical notification for very low battery" {
  run bg_send_battery_notification "5" "Discharging"
  
  assert_success
  
  # Check the notification log
  run cat "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/notifications.log"
  
  assert_success
  assert_output --partial "Critical"
  assert_output --partial "-u critical"
}
