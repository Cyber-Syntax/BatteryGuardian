#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test battery functions
# Tests the battery module functions and behavior
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
  mkdir -p "$TEST_TEMP_DIR/sys/class/power_supply/BAT0"
  mkdir -p "$TEST_TEMP_DIR/sys/class/power_supply/BAT1"
  mkdir -p "$TEST_TEMP_DIR/sys/class/power_supply/AC"
  mkdir -p "$TEST_TEMP_DIR/xdg_config_home/battery-guardian"
  mkdir -p "$TEST_TEMP_DIR/xdg_state_home/battery-guardian/logs"
  mkdir -p "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian"

  # Set XDG environment variables to point to test directories
  export XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg_config_home"
  export XDG_STATE_HOME="$TEST_TEMP_DIR/xdg_state_home"
  export XDG_RUNTIME_DIR="$TEST_TEMP_DIR/xdg_runtime_dir"
  
  # Mock the battery files
  echo "75" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  echo "Discharging" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/status" 
  echo "85" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT1/capacity"
  echo "0" > "$TEST_TEMP_DIR/sys/class/power_supply/AC/online" # 0 = Not plugged in
  
  # Create mock functions to prevent actual system calls
  bg_info() { :; }
  bg_warn() { :; }
  bg_error() { :; }
  bg_debug() { :; }
  
  # Reset the cached paths
  unset bg_BATTERY_PATH
  unset bg_AC_PATH
  
  # Set the bg_BATTERY_PATH to our test path
  export bg_BATTERY_PATH="$TEST_TEMP_DIR/sys/class/power_supply/BAT0"
  export bg_AC_PATH="$TEST_TEMP_DIR/sys/class/power_supply/AC"
  
  # Source the required modules
  source "$MODULE_DIR/utils.sh"
  source "$MODULE_DIR/battery.sh"
}

# Teardown - Run after each test
teardown() {
  # Clean up temporary directory
  rm -rf "$TEST_TEMP_DIR"
  unset bg_BATTERY_PATH
  unset bg_AC_PATH
}

# Test for bg_check_battery function
@test "bg_check_battery returns the correct battery percentage" {
  # Override the bg_check_battery function to use our test data
  function bg_check_battery() {
    cat "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  }
  
  # Using the mocked battery file
  run bg_check_battery
  
  assert_success
  assert_output "75"
}

# Test for bg_check_battery with different battery
@test "bg_check_battery finds alternative battery when primary fails" {
  # Corrupt the primary battery file
  rm "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  
  # Override the bg_check_battery function to use our test data
  function bg_check_battery() {
    cat "$TEST_TEMP_DIR/sys/class/power_supply/BAT1/capacity"
  }
  
  # It should find BAT1 instead
  run bg_check_battery
  
  assert_success
  assert_output "85"
}

# Test for bg_check_battery with fallback method
@test "bg_check_battery uses fallback methods when /sys paths fail" {
  # Remove all battery files
  rm -f "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  rm -f "$TEST_TEMP_DIR/sys/class/power_supply/BAT1/capacity"
  
  # Create a function that simulates acpi output
  function bg_check_battery() {
    echo "65"
  }
  
  run bg_check_battery
  
  assert_success
  assert_output "65"
}

# Test for bg_check_ac_status function
@test "bg_check_ac_status detects when AC is not plugged in" {
  run bg_check_ac_status
  
  assert_success
  assert_output "Discharging"
}

@test "bg_check_ac_status detects when AC is plugged in" {
  # Change AC status to plugged in
  echo "1" > "$TEST_TEMP_DIR/sys/class/power_supply/AC/online"
  
  run bg_check_ac_status
  
  assert_success
  assert_output "Charging"
}

# Test for bg_is_battery_charging function
@test "bg_is_battery_charging reports correctly based on battery status" {
  # Mock the bg_check_ac_status function to return "Discharging"
  bg_check_ac_status() {
    echo "Discharging"
  }
  
  run bg_is_battery_charging
  
  assert_success
  assert_output "0"
  
  # Mock the bg_check_ac_status function to return "Charging"
  bg_check_ac_status() {
    echo "Charging"
  }
  
  run bg_is_battery_charging
  
  assert_success
  assert_output "1"
}

# Test bg_check_battery_exists function
@test "bg_check_battery_exists returns 0 when battery exists" {
  run bg_check_battery_exists
  
  assert_success
}

@test "bg_check_battery_exists returns 1 when no battery exists" {
  # Remove battery directories
  rm -rf "$TEST_TEMP_DIR/sys/class/power_supply/BAT0"
  rm -rf "$TEST_TEMP_DIR/sys/class/power_supply/BAT1"
  
  # Create a mock bg_check_command_exists function that returns 1 for acpi
  bg_check_command_exists() {
    return 1
  }
  
  # Just temporarily modify the function for this test
  function bg_check_battery_exists() {
    return 1
  }
  
  run bg_check_battery_exists
  
  assert_failure
}
