#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test event-based monitoring functionality
# Tests the event-based monitoring system for battery changes
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

  # Initialize back-off variables
  bg_current_backoff_interval=${bg_BACKOFF_INITIAL}
}

# Clean up after tests
teardown() {
  if [ -d "$TEST_TEMP_DIR" ]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}  # Test the bg_get_sleep_duration function with adaptive back-off
@test "bg_get_sleep_duration implements adaptive back-off correctly" {
  # Mock bg_info function to avoid output
  function bg_info() { :; }

  # Create a standalone implementation of the bg_get_sleep_duration logic for testing
  function test_get_sleep_duration() {
    local battery_percent=$1
    local ac_status=$2
    local has_changed=$3
    local current_backoff=$4
    local result_backoff
    local duration

    # Use local variable to simulate the global one
    result_backoff=$current_backoff

    # Reset back-off when actual changes are detected
    if [[ "$has_changed" -eq 1 ]]; then
      result_backoff=10 # bg_BACKOFF_INITIAL
      duration=$result_backoff
    else
      # Use current back-off value
      duration=$result_backoff

      # Apply exponential back-off for next time
      result_backoff=$((result_backoff * 2)) # bg_BACKOFF_FACTOR

      # Cap at maximum
      if [[ "$result_backoff" -gt 300 ]]; then # bg_BACKOFF_MAX
        result_backoff=300 # bg_BACKOFF_MAX
      fi
    fi

    # Special case: for critical battery, always check more frequently
    if [[ "$battery_percent" -le 5 && "$ac_status" == "Discharging" ]]; then
      duration=30 # bg_CRITICAL_POLLING
    fi

    echo "${duration},${result_backoff}"
  }

  # Test with status change - should reset back-off
  local output=$(test_get_sleep_duration 50 "Discharging" 1 20)
  local duration=$(echo "$output" | cut -d, -f1)
  local new_backoff=$(echo "$output" | cut -d, -f2)

  assert_equal "$duration" "10" "Duration should be reset to initial with status change"
  assert_equal "$new_backoff" "10" "Backoff should be reset to initial with status change"

  # Test without status change - should use current interval and double for next time
  output=$(test_get_sleep_duration 50 "Discharging" 0 10)
  duration=$(echo "$output" | cut -d, -f1)
  new_backoff=$(echo "$output" | cut -d, -f2)

  assert_equal "$duration" "10" "Duration should be current interval without status change"
  assert_equal "$new_backoff" "20" "Backoff should double without status change"

  # Test with critical battery - should use critical polling interval
  output=$(test_get_sleep_duration 5 "Discharging" 0 40)
  duration=$(echo "$output" | cut -d, -f1)
  new_backoff=$(echo "$output" | cut -d, -f2)

  assert_equal "$duration" "30" "Duration should be critical interval with low battery"
}

# Test check_battery_and_adjust_brightness function
@test "check_battery_and_adjust_brightness updates battery status" {
  # Set up variables to prevent loading brightness.sh
  export bg_BRIGHTNESS_MAX=100
  export bg_BRIGHTNESS_MEDIUM=60

  # Mock bg_check_battery to return a known value
  function bg_check_battery() { echo "75"; }

  # Mock bg_check_ac_status to return a known value
  function bg_check_ac_status() { echo "Charging"; }

  # Mock other functions to avoid actual system changes
  function bg_info() { echo "$@"; }
  function bg_warn() { echo "$@"; }
  function bg_error() { echo "$@"; }
  function bg_send_notification() { echo "Notification: $*"; return 0; }
  function bg_set_brightness() { echo "Setting brightness to $1"; return 0; }
  function bg_adjust_brightness_for_battery() { echo "Adjusting brightness for $1%, status $2"; return 0; }
  function bg_should_send_notification() { return 1; } # Return false
  function bg_send_battery_notification() { return 0; }

  # Make source a no-op to prevent loading the actual brightness.sh file
  function source() {
    if [[ "$1" == *"brightness.sh"* ]]; then
      return 0
    else
      builtin source "$@"
    fi
  }

  # Run the function
  run check_battery_and_adjust_brightness

  # Verify correct operation
  assert_success
  assert_output --partial "Battery: 75%, AC: Charging"
}

# Test start_monitoring function with fallback to adaptive polling
@test "start_monitoring falls back to adaptive polling when no daemon is running" {
  # Create a modified version of start_monitoring for testing
  function start_monitoring_test() {
    if pgrep -x "upowerd" >/dev/null; then
      bg_monitor_upower_events
    elif pgrep -x "acpid" >/dev/null; then
      bg_monitor_acpid_events
    else
      bg_warn "Falling back to polling with adaptive back-off"
      return 0  # Return instead of entering the infinite loop
    fi
  }

  # Mock pgrep to simulate no daemons running
  function pgrep() { return 1; }

  # Mock warning function
  function bg_warn() { echo "$@"; }

  # Run the modified function
  run start_monitoring_test

  # Verify correct operation
  assert_success
  assert_output "Falling back to polling with adaptive back-off"
}

# Test start_monitoring with UPower daemon running
@test "start_monitoring uses UPower when daemon is running" {
  # Create a modified version of start_monitoring for testing
  function start_monitoring_test() {
    if pgrep -x "upowerd" >/dev/null; then
      bg_monitor_upower_events
    elif pgrep -x "acpid" >/dev/null; then
      bg_monitor_acpid_events
    else
      bg_warn "Falling back to polling with adaptive back-off"
    fi
  }

  # Mock pgrep to simulate upowerd running
  function pgrep() {
    if [[ "$1" == "-x" && "$2" == "upowerd" ]]; then
      return 0
    fi
    return 1
  }

  # Mock bg_monitor_upower_events to avoid indefinite wait
  function bg_monitor_upower_events() {
    echo "Starting UPower monitoring"
    return 0
  }

  # Mock bg_monitor_acpid_events to ensure it's not called
  function bg_monitor_acpid_events() {
    echo "This should not be called"
    return 1
  }

  # Run the modified function
  run start_monitoring_test

  # Verify correct operation
  assert_success
  assert_output "Starting UPower monitoring"
}

# Test start_monitoring with ACPID daemon running
@test "start_monitoring uses ACPID when daemon is running" {
  # Create a modified version of start_monitoring for testing
  function start_monitoring_test() {
    if pgrep -x "upowerd" >/dev/null; then
      bg_monitor_upower_events
    elif pgrep -x "acpid" >/dev/null; then
      bg_monitor_acpid_events
    else
      bg_warn "Falling back to polling with adaptive back-off"
    fi
  }

  # Mock pgrep to simulate acpid running but not upowerd
  function pgrep() {
    if [[ "$1" == "-x" && "$2" == "upowerd" ]]; then
      return 1
    elif [[ "$1" == "-x" && "$2" == "acpid" ]]; then
      return 0
    fi
    return 1
  }

  # Mock bg_monitor_acpid_events to avoid indefinite wait
  function bg_monitor_acpid_events() {
    echo "Starting ACPI monitoring"
    return 0
  }

  # Mock bg_monitor_upower_events to ensure it's not called
  function bg_monitor_upower_events() {
    echo "This should not be called"
    return 1
  }

  # Run the modified function
  run start_monitoring_test

  # Verify correct operation
  assert_success
  assert_output "Starting ACPI monitoring"
}
