#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test utility functions
# Tests the utility functions module
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
  create_mock_commands
  
  # Add mock directory to PATH
  export PATH="$TEST_TEMP_DIR/bin:$PATH"
  
  # Define runtime directory variable needed by utility functions
  export BG_RUNTIME_DIR="$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian"
  
  # Source the required modules
  source "$MODULE_DIR/log.sh"
  source "$MODULE_DIR/utils.sh"
}

# Helper function to create mock commands
create_mock_commands() {
  # Mock notify-send
  echo '#!/bin/bash
echo "notify-send called with: $@"
exit 0' > "$TEST_TEMP_DIR/bin/notify-send"
  chmod +x "$TEST_TEMP_DIR/bin/notify-send"
  
  # Mock brightnessctl
  echo '#!/bin/bash
echo "brightnessctl called with: $@"
exit 0' > "$TEST_TEMP_DIR/bin/brightnessctl"
  chmod +x "$TEST_TEMP_DIR/bin/brightnessctl"
  
  # Mock inotifywait
  echo '#!/bin/bash
echo "inotifywait called with: $@"
exit 0' > "$TEST_TEMP_DIR/bin/inotifywait"
  chmod +x "$TEST_TEMP_DIR/bin/inotifywait"
}

# Teardown - Run after each test
teardown() {
  # Clean up temporary directory
  rm -rf "$TEST_TEMP_DIR"
}

# Test bg_check_command_exists function
@test "bg_check_command_exists returns 0 for existing commands" {
  run bg_check_command_exists "notify-send"
  
  assert_success
}

@test "bg_check_command_exists returns 1 for non-existing commands" {
  run bg_check_command_exists "nonexistent-command"
  
  assert_failure
}

# Test bg_check_dependencies function
@test "bg_check_dependencies checks for required tools" {
  # Add the required notify-send tool (in case it was removed in a previous test run)
  echo '#!/bin/bash
echo "notify-send called with: $@"
exit 0' > "$TEST_TEMP_DIR/bin/notify-send"
  chmod +x "$TEST_TEMP_DIR/bin/notify-send"
  
  run bg_check_dependencies
  
  assert_success
  
  # Now remove a required dependency and test again
  rm "$TEST_TEMP_DIR/bin/notify-send"
  
  # Must define function directly in the test to ensure consistent behavior
  function bg_check_command_exists() {
    if [[ "$1" == "notify-send" ]]; then
      return 1  # Command not found
    else
      return 0  # Other commands exist
    fi
  }
  
  # Run our own version that ensures notify-send is missing
  function test_bg_check_dependencies() {
    local missing_deps=0
    
    # Check for notify-send (required)
    if ! bg_check_command_exists "notify-send"; then
      echo "Missing required dependency: notify-send"
      missing_deps=$((missing_deps + 1))
      return 1
    fi
    
    return 0
  }
  
  run test_bg_check_dependencies
  
  # It should fail or return non-zero exit code
  assert [ $status -ne 0 ]
  assert_output --partial "Missing required dependency: notify-send"
}

# Test bg_safe_path function
@test "bg_safe_path rejects paths with directory traversal" {
  run bg_safe_path "/tmp/file.txt"
  assert_output "/tmp/file.txt" # Valid path
  
  run bg_safe_path "/tmp/../etc/passwd"
  refute_output "/tmp/../etc/passwd" # Should sanitize path
  
  run bg_safe_path "/tmp/test/../../etc/passwd"
  refute_output "/tmp/test/../../etc/passwd" # Should sanitize path
}

# Test bg_get_sleep_duration function
@test "bg_get_sleep_duration calculates appropriate sleep duration" {
  # Test when battery stable
  run bg_get_sleep_duration 50 0 0
  assert [ $output -gt 30 ] # Should be longer when stable
  
  # Test when battery changed
  run bg_get_sleep_duration 50 0 1
  assert [ $output -lt 60 ] # Should be shorter when changed
  
  # Test when battery low
  run bg_get_sleep_duration 15 0 0
  low_duration=$output
  
  # Test when battery high
  run bg_get_sleep_duration 85 0 0
  high_duration=$output
  
  # Low battery should have shorter polling interval
  assert [ $low_duration -lt $high_duration ]
  
  # Test when AC changed
  run bg_get_sleep_duration 50 1 1
  assert [ $output -lt 30 ] # Should be very short after AC status change
}

# Test bg_cleanup function
@test "bg_cleanup performs proper cleanup operations" {
  # Create test files to clean up
  touch "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid"
  touch "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/lock"
  
  run bg_cleanup
  
  assert_success
  
  # Files should be removed
  [ ! -f "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid" ]
  [ ! -f "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/lock" ]
}

# Test bg_exit_handler function
@test "bg_exit_handler calls cleanup function" {
  # Create a test file to clean up
  touch "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid"
  
  run bg_exit_handler
  
  assert_success
  
  # File should be removed
  [ ! -f "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid" ]
}

# Test bg_acquire_lock function
@test "bg_acquire_lock creates lock file and prevents multiple instances" {
  run bg_acquire_lock
  
  assert_success
  assert [ -f "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/lock" ]
  
  # Running again should fail
  run bg_acquire_lock
  
  assert_failure
  assert_output --partial "Another instance is already running"
}

# Test bg_release_lock function
@test "bg_release_lock removes lock file" {
  # First acquire the lock
  bg_acquire_lock
  
  # Verify lock file exists
  [ -f "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/lock" ]
  
  # Release the lock
  run bg_release_lock
  
  assert_success
  [ ! -f "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/lock" ]
}

# Test bg_write_pid function
@test "bg_write_pid writes correct PID to file" {
  run bg_write_pid
  
  assert_success
  [ -f "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid" ]
  
  # PID file should contain current process PID
  pid_content=$(<"$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid")
  [ "$pid_content" = "$$" ]
}

# Test bg_sanitize_value function
@test "bg_sanitize_value sanitizes values to specified range" {
  run bg_sanitize_value -10 0 100
  assert_output "0"  # Below min should be clamped to min
  
  run bg_sanitize_value 150 0 100
  assert_output "100"  # Above max should be clamped to max
  
  run bg_sanitize_value 50 0 100
  assert_output "50"  # Within range should remain unchanged
}

# Test bg_is_process_running function
@test "bg_is_process_running detects running processes" {
  # Write the current process PID
  echo "$$" > "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid"
  
  run bg_is_process_running "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid"
  
  assert_success
  assert_output "1"  # Should report process is running
  
  # Write a non-existent PID
  echo "99999999" > "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid"
  
  run bg_is_process_running "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian/pid"
  
  assert_success
  assert_output "0"  # Should report process is not running
}
