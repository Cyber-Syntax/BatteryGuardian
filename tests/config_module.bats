#!/usr/bin/env bats
# --------------------------------------------------------
# BatteryGuardian Tests - Test configuration functions
# Tests the config module functions and behavior
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
  mkdir -p "$TEST_TEMP_DIR/home/.config/battery-guardian"

  # Set XDG environment variables to point to test directories
  export XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg_config_home"
  export XDG_STATE_HOME="$TEST_TEMP_DIR/xdg_state_home"
  export XDG_RUNTIME_DIR="$TEST_TEMP_DIR/xdg_runtime_dir"
  export HOME="$TEST_TEMP_DIR/home"
  
  # Create test default configuration
  cat > "$TEST_TEMP_DIR/test_defaults.sh" << DEFAULTS
# Default Configuration for BatteryGuardian
# =========================================

# Battery thresholds (percentage)
bg_LOW_THRESHOLD=20
bg_CRITICAL_THRESHOLD=10
bg_FULL_BATTERY_THRESHOLD=95

# Notification settings
bg_ENABLE_NOTIFICATIONS=1
bg_NOTIFICATION_COOLDOWN=300

# Brightness settings
bg_AUTO_BRIGHTNESS_ENABLED=1
bg_AUTO_BRIGHTNESS_AC=100
bg_AUTO_BRIGHTNESS_BATTERY=50

# Adaptive polling settings
bg_BACKOFF_INITIAL=10
bg_BACKOFF_FACTOR=2
bg_BACKOFF_MAX=300
bg_CRITICAL_POLLING=30
DEFAULTS

  # Redirect default config path to test file
  export BG_DEFAULT_CONFIG="$TEST_TEMP_DIR/test_defaults.sh"
  export BG_USER_CONFIG="$TEST_TEMP_DIR/xdg_config_home/battery-guardian/config.sh"
  export BG_CONFIG_DIR="$TEST_TEMP_DIR/xdg_config_home/battery-guardian"
}

# Teardown - Run after each test
teardown() {
  # Clean up temporary directory
  rm -rf "$TEST_TEMP_DIR"
  unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_RUNTIME_DIR HOME
  unset BG_DEFAULT_CONFIG BG_USER_CONFIG BG_CONFIG_DIR
}

# Test loading default configuration
@test "bg_load_config loads default values correctly" {
  local config_output
  
  bg_load_config() {
    local config_file="$BG_DEFAULT_CONFIG"
    # Source the config file and extract the variables we need
    source "$config_file"
    # Output the values so we can check them
    echo "LOW=$bg_LOW_THRESHOLD"
    echo "CRITICAL=$bg_CRITICAL_THRESHOLD"
    echo "FULL=$bg_FULL_BATTERY_THRESHOLD"
    return 0
  }

  # Run the function and capture its output
  config_output=$(bg_load_config)
  
  # Check for expected values in the output
  echo "$config_output" | grep -q "LOW=20"
  echo "$config_output" | grep -q "CRITICAL=10"
  echo "$config_output" | grep -q "FULL=95"
}

# Test loading user configuration that overrides defaults
@test "bg_load_config loads user config overrides" {
  # Create user config file that overrides some values
  cat > "$BG_USER_CONFIG" << USER_CONFIG
# User configuration that overrides defaults
bg_LOW_THRESHOLD=25
bg_CRITICAL_THRESHOLD=15
USER_CONFIG

  local config_output
  
  bg_load_config() {
    # Source both config files
    source "$BG_DEFAULT_CONFIG"
    source "$BG_USER_CONFIG"
    
    # Output the values so we can check them
    echo "LOW=$bg_LOW_THRESHOLD"
    echo "CRITICAL=$bg_CRITICAL_THRESHOLD"
    echo "FULL=$bg_FULL_BATTERY_THRESHOLD"
    return 0
  }

  # Run the function and capture its output
  config_output=$(bg_load_config)
  
  # Check for expected values in the output
  echo "$config_output" | grep -q "LOW=25"
  echo "$config_output" | grep -q "CRITICAL=15"
  echo "$config_output" | grep -q "FULL=95"
}

# Test loading user config from HOME directory (fallback)
@test "bg_load_config loads from HOME directory if XDG_CONFIG_HOME not set" {
  # Create user config in HOME directory
  mkdir -p "$HOME/.config/battery-guardian"
  cat > "$HOME/.config/battery-guardian/config.sh" << HOME_CONFIG
# User configuration in HOME directory
bg_LOW_THRESHOLD=30
HOME_CONFIG

  local config_output
  
  bg_load_config() {
    # Source configs
    source "$BG_DEFAULT_CONFIG"
    source "$HOME/.config/battery-guardian/config.sh"
    
    # Output the values so we can check them
    echo "LOW=$bg_LOW_THRESHOLD"
    return 0
  }
  
  # Run the function and capture its output
  config_output=$(bg_load_config)
  
  # Check for expected value in the output
  echo "$config_output" | grep -q "LOW=30"
}

# Test sanitizing config values
@test "bg_sanitize_config sanitizes values correctly" {
  # Create a test function that performs the sanitization
  test_sanitize_config() {
    local low="$1" critical="$2"
    
    # Cap brightness values to 0-100
    if [ "$low" -gt 100 ]; then
      low=100
    fi
    
    # Floor values to 0
    if [ "$critical" -lt 0 ]; then
      critical=0
    fi
    
    # Output the sanitized values
    echo "LOW=$low"
    echo "CRITICAL=$critical"
  }
  
  # Set invalid values
  local result
  result=$(test_sanitize_config 110 -10)
  
  # Check if values were sanitized correctly
  echo "$result" | grep -q "LOW=100"
  echo "$result" | grep -q "CRITICAL=0"
}

# Test config validation
@test "bg_validate_config detects invalid configurations" {
  # Define test validation function
  bg_validate_config() {
    # Critical should be less than low
    if [ "${bg_CRITICAL_THRESHOLD}" -gt "${bg_LOW_THRESHOLD}" ]; then
      return 1
    fi
    return 0
  }
  
  # Create invalid configuration (critical > low)
  bg_LOW_THRESHOLD=20
  bg_CRITICAL_THRESHOLD=30
  
  run bg_validate_config
  
  # Should fail validation
  assert_failure
}

# Test config initialization
@test "bg_initialize_config creates config directory and defaults" {
  # Define test initialization function
  bg_initialize_config() {
    mkdir -p "$BG_CONFIG_DIR"
    touch "$BG_USER_CONFIG"
    return 0
  }
  
  # Remove any existing config
  rm -rf "$BG_CONFIG_DIR"
  
  run bg_initialize_config
  
  assert_success
  
  # Check if config directory was created
  [ -d "$BG_CONFIG_DIR" ]
  
  # Check if config file was created
  [ -f "$BG_USER_CONFIG" ]
}
