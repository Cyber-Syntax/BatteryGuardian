#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test adaptive polling functionality
# Tests the adaptive back-off algorithm for polling
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
UTILS_PATH="$SRC_DIR/modules/utils.sh"

# Set up test environment
setup() {
  mkdir -p "$TEST_TEMP_DIR"
  # Create test environment variables
  export BG_SCRIPT_DIR="$SRC_DIR"
  export BG_PARENT_DIR="$REPO_ROOT"
  export previous_battery_percent=50
  export previous_ac_status="Discharging"
  export bg_BACKOFF_INITIAL=10
  export bg_BACKOFF_FACTOR=2
  export bg_BACKOFF_MAX=300
  export bg_CRITICAL_POLLING=30
  
  # Source necessary modules for testing
  source "$SRC_DIR/modules/log.sh"
  source "$SRC_DIR/modules/utils.sh"
  
  # Reset back-off for tests
  bg_current_backoff_interval=$bg_BACKOFF_INITIAL
}

# Clean up after tests
teardown() {
  if [ -d "$TEST_TEMP_DIR" ]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

# Test initial back-off duration is correct
@test "Sleep duration starts at initial back-off value" {
  # Run the function with has_changed=1 (status has changed)
  run bg_get_sleep_duration 50 "Discharging" 1
  
  # Verify it returns the initial back-off
  assert_success
  assert_output "10"
}

# Test exponential back-off increases correctly
@test "Sleep duration follows exponential back-off" {
  # First call with no change
  run bg_get_sleep_duration 50 "Discharging" 0
  assert_output "10"
  # Current interval should now be 20
  
  # Second call with no change
  bg_current_backoff_interval=20
  run bg_get_sleep_duration 50 "Discharging" 0
  assert_output "20"
  # Current interval should now be 40
  
  # Third call with no change
  bg_current_backoff_interval=40
  run bg_get_sleep_duration 50 "Discharging" 0
  assert_output "40"
  # Current interval should now be 80
}

# Test back-off resets when changes occur
@test "Sleep duration resets when battery status changes" {
  # Set the current interval to a higher value
  bg_current_backoff_interval=80
  
  # Run the function with has_changed=1 (status has changed)
  run bg_get_sleep_duration 50 "Discharging" 1
  
  # Verify it returns the initial back-off
  assert_success
  assert_output "10"
}

# Test that back-off is capped at the maximum value
@test "Sleep duration is capped at maximum value" {
  # Set the current interval to just below the maximum
  bg_current_backoff_interval=160
  
  # Run the function with has_changed=0 (status has not changed)
  run bg_get_sleep_duration 50 "Discharging" 0
  
  # Verify it returns the current value
  assert_success
  assert_output "160"
  
  # Next interval would be 320, but should be capped at 300
  # Set the current interval above the cap to test
  bg_current_backoff_interval=320
  
  # Run again
  run bg_get_sleep_duration 50 "Discharging" 0
  
  # Verify it's capped at the maximum
  assert_success
  assert_output "300"
}

# Test critical battery level uses fixed polling
@test "Critical battery level uses fixed polling interval" {
  # Set the current interval to a high value
  bg_current_backoff_interval=300
  
  # Run the function with a critical battery level
  run bg_get_sleep_duration 5 "Discharging" 0
  
  # Verify it returns the critical polling interval
  assert_success
  assert_output "30"
}
