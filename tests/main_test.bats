#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test main script functiona  # Create a temporary modified main script for testing
  cat > "$TEST_TEMP_DIR/main_test.sh" << 'EOF'
#!/usr/bin/env bash
# Modified main.sh for testing

# Ensure script exits on errors and undefined variables
set -o errexit -o nounset -o pipefail

# ---- Define paths ----
# Determine the absolute path to this script
BG_SCRIPT_DIR=""
BG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BG_SCRIPT_DIR

# BG_PARENT_DIR is used to reference files in the parent directory (like configs)
BG_PARENT_DIR=""
BG_PARENT_DIR="$(dirname "$BG_SCRIPT_DIR")"
readonly BG_PARENT_DIR
export BG_PARENT_DIR

# ---- Load modules in the correct order ----
source "$MAIN_SCRIPT_DIR/modules/log.sh"
source "$MAIN_SCRIPT_DIR/modules/utils.sh"
source "$MAIN_SCRIPT_DIR/modules/config.sh"
source "$MAIN_SCRIPT_DIR/modules/battery.sh"
source "$MAIN_SCRIPT_DIR/modules/brightness.sh"
source "$MAIN_SCRIPT_DIR/modules/notification.sh"

# Mock monitoring functions for tests
start_monitoring() {
  echo "Monitoring started (mock)"
  return 0
}

bg_monitor_upower_events() {
  echo "UPower monitoring started (mock)"
  return 0
}

bg_monitor_acpid_events() {
  echo "ACPID monitoring started (mock)"
  return 0
}

bg_monitor_sysfs_events() {
  echo "sysfs monitoring started (mock)"
  return 0
}

# ---- Main Function ----
bg_main() {
  echo "Modules loaded successfully"
}
EOF

  # Set the file executable
  chmod +x "$TEST_TEMP_DIR/main_test.sh"
  
  # Export the main script directory path for the test script to use
  export MAIN_SCRIPT_DIR="$SRC_DIR"
  
  # Source the test main script instead of the real one
  source "$TEST_TEMP_DIR/main_test.sh"
   Tests the main script integration of modules
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
MAIN_SCRIPT="$SRC_DIR/main.sh"

# Setup - Run before each test
setup() {
  # Create a temporary directory structure
  mkdir -p "$TEST_TEMP_DIR/sys/class/power_supply/BAT0"
  mkdir -p "$TEST_TEMP_DIR/xdg_config_home/battery-guardian"
  mkdir -p "$TEST_TEMP_DIR/xdg_state_home/battery-guardian/logs"
  mkdir -p "$TEST_TEMP_DIR/xdg_runtime_dir/battery-guardian"
  mkdir -p "$TEST_TEMP_DIR/bin"

  # Set XDG environment variables to point to test directories
  export XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg_config_home"
  export XDG_STATE_HOME="$TEST_TEMP_DIR/xdg_state_home"
  export XDG_RUNTIME_DIR="$TEST_TEMP_DIR/xdg_runtime_dir"

  # Mock battery and AC adapter files
  echo "75" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/capacity"
  echo "Discharging" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/status"
  echo "0" > "$TEST_TEMP_DIR/sys/class/power_supply/BAT0/online"

  # Create mock commands
  create_mock_commands

  # Add mock directory to PATH
  export PATH="$TEST_TEMP_DIR/bin:$PATH"

  # Override bg_check_battery_exists to always return true
  bg_check_battery_exists() {
    return 0
  }

  # Override bg_check_lock to not actually lock
  bg_check_lock() {
    return 0
  }

  # Create basic config file
  cat > "$TEST_TEMP_DIR/xdg_config_home/battery-guardian/config.sh" << EOF
# Test configuration
bg_BRIGHTNESS_CONTROL_ENABLED=true
bg_LOW_THRESHOLD=20
bg_CRITICAL_THRESHOLD=10
bg_FULL_BATTERY_THRESHOLD=90
EOF
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

  # Mock sleep command to make tests run faster
  echo '#!/bin/bash
# Do nothing but pretend to sleep
exit 0' > "$TEST_TEMP_DIR/bin/sleep"
  chmod +x "$TEST_TEMP_DIR/bin/sleep"
}

# Teardown - Run after each test
teardown() {
  # Clean up temporary directory
  rm -rf "$TEST_TEMP_DIR"
}

# Test that main function sources all required modules
@test "Main script sources all required modules" {
  # Save function references to restore later
  if declare -f check_battery_and_adjust_brightness > /dev/null; then
    orig_check_battery_and_adjust_brightness=$(declare -f check_battery_and_adjust_brightness)
  fi

  # Mock the monitoring and potentially infinite loop functions
  check_battery_and_adjust_brightness() {
    echo "Battery checked and brightness adjusted (mock)"
    return 0
  }
  
  start_monitoring() {
    echo "Monitoring started (mock)"
    return 0
  }
  
  bg_monitor_upower_events() {
    echo "UPower monitoring started (mock)"
    return 0
  }
  
  bg_monitor_acpid_events() {
    echo "ACPID monitoring started (mock)"
    return 0
  }
  
  bg_monitor_sysfs_events() {
    echo "sysfs monitoring started (mock)"
    return 0
  }
  
  sleep() {
    echo "Sleep called with: $@ (mock - not actually sleeping)"
    return 0
  }
  
  # Source main script with mocks in place
  source "$MAIN_SCRIPT"
  
  # Define dummy function to replace the main function execution
  bg_main() {
    echo "Modules loaded successfully"
  }
  
  # Check if modules were loaded by checking for a function from each module
  type bg_log >/dev/null 2>&1 || exit 1
  type bg_check_battery >/dev/null 2>&1 || exit 1
  type bg_set_brightness >/dev/null 2>&1 || exit 1
  type bg_load_config >/dev/null 2>&1 || exit 1
  type bg_send_notification >/dev/null 2>&1 || exit 1
  
  # Restore original functions if they existed
  if [[ -n "$orig_check_battery_and_adjust_brightness" ]]; then
    eval "$orig_check_battery_and_adjust_brightness"
  fi

  # Check exit code
  [ $? -eq 0 ]
}

# Test the main script can load configuration
@test "Main script loads configuration correctly" {
  # Save function references to restore later
  if declare -f check_battery_and_adjust_brightness > /dev/null; then
    orig_check_battery_and_adjust_brightness=$(declare -f check_battery_and_adjust_brightness)
  fi

  # Mock the monitoring and potentially infinite loop functions
  check_battery_and_adjust_brightness() {
    echo "Battery checked and brightness adjusted (mock)"
    return 0
  }
  
  start_monitoring() {
    echo "Monitoring started (mock)"
    return 0
  }
  
  bg_monitor_upower_events() {
    echo "UPower monitoring started (mock)"
    return 0
  }
  
  bg_monitor_acpid_events() {
    echo "ACPID monitoring started (mock)"
    return 0
  }
  
  bg_monitor_sysfs_events() {
    echo "sysfs monitoring started (mock)"
    return 0
  }
  
  # Redirect stderr to /dev/null to suppress error messages
  run bash -c "BG_DEFAULT_CONFIG=\"$TEST_TEMP_DIR/xdg_config_home/battery-guardian/config.sh\" source \"$SRC_DIR/modules/config.sh\" 2>/dev/null && bg_load_config 2>/dev/null && echo \$bg_LOW_THRESHOLD"

  assert_success
  assert_output "20"
  
  # Restore original functions if they existed
  if [[ -n "$orig_check_battery_and_adjust_brightness" ]]; then
    eval "$orig_check_battery_and_adjust_brightness"
  fi
}
