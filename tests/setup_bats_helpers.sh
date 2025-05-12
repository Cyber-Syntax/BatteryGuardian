#!/usr/bin/env bash
# --------------------------------------------------------
# BatteryGuardian - BATS Test Helper Installation
# Sets up BATS helper libraries for testing
# Author: Cyber-Syntax
# License: BSD 3-Clause License
# --------------------------------------------------------

# Enable strict error handling
set -o errexit -o nounset -o pipefail

# Constants
readonly BTH_SCRIPT_NAME="$(basename "$0")"
readonly BTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BTH_HELPER_DIR="${BTH_DIR}/test_helper"
readonly BTH_TEMP_DIR="${BTH_HELPER_DIR}/_temp"
readonly BTH_LOG_FILE="${BTH_DIR}/setup_bats_helpers.log"

# Helper library information
declare -A BTH_LIBS=(
  ["bats-support"]="https://github.com/bats-core/bats-support.git"
  ["bats-assert"]="https://github.com/bats-core/bats-assert.git"
  ["bats-mock"]="https://github.com/grayhemp/bats-mock.git"
)

# ---- Logging Functions ----

# Debug message
bth_debug() {
  local timestamp
  timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
  echo -e "[${timestamp}] [DEBUG] $*" >> "${BTH_LOG_FILE}"
}

# Informational message
bth_info() {
  local timestamp
  timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
  echo -e "[${timestamp}] [INFO] $*" | tee -a "${BTH_LOG_FILE}"
}

# Warning message
bth_warn() {
  local timestamp
  timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
  echo -e "[${timestamp}] [WARN] $*" | tee -a "${BTH_LOG_FILE}" >&2
}

# Error message
bth_error() {
  local timestamp
  timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
  echo -e "[${timestamp}] [ERROR] $*" | tee -a "${BTH_LOG_FILE}" >&2
}

# ---- Utility Functions ----

# Check if required commands are available
bth_check_dependencies() {
  bth_info "Checking dependencies..."

  local missing_deps=()
  local required_cmds=("git" "mkdir" "rm" "chmod")

  for cmd in "${required_cmds[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing_deps+=("${cmd}")
    fi
  done

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    bth_error "Missing required dependencies: ${missing_deps[*]}"
    return 1
  fi

  bth_info "All dependencies are available."
  return 0
}

# Create necessary directories
bth_create_directories() {
  bth_info "Creating necessary directories..."

  if [[ -d "${BTH_HELPER_DIR}" ]]; then
    bth_info "Helper directory already exists: ${BTH_HELPER_DIR}"
  else
    mkdir -p "${BTH_HELPER_DIR}" || {
      bth_error "Failed to create helper directory: ${BTH_HELPER_DIR}"
      return 1
    }
    bth_info "Created helper directory: ${BTH_HELPER_DIR}"
  fi

  # Create temporary directory for downloads
  if [[ -d "${BTH_TEMP_DIR}" ]]; then
    rm -rf "${BTH_TEMP_DIR}" || {
      bth_error "Failed to clean existing temporary directory: ${BTH_TEMP_DIR}"
      return 1
    }
  fi

  mkdir -p "${BTH_TEMP_DIR}" || {
    bth_error "Failed to create temporary directory: ${BTH_TEMP_DIR}"
    return 1
  }
  bth_info "Created temporary directory: ${BTH_TEMP_DIR}"

  return 0
}

# Cleanup function
bth_cleanup() {
  bth_debug "Performing cleanup..."

  if [[ -d "${BTH_TEMP_DIR}" ]]; then
    bth_debug "Removing temporary directory: ${BTH_TEMP_DIR}"
    rm -rf "${BTH_TEMP_DIR}" || bth_warn "Failed to remove temporary directory: ${BTH_TEMP_DIR}"
  fi

  bth_debug "Cleanup completed."
}

# Download and install a BATS helper library
bth_install_helper() {
  local lib_name="$1"
  local lib_repo="$2"
  local lib_target_dir="${BTH_HELPER_DIR}/${lib_name}"

  bth_info "Installing ${lib_name}..."

  # Check if library directory already exists
  if [[ -d "${lib_target_dir}" ]]; then
    bth_info "${lib_name} is already installed. Removing to reinstall..."
    rm -rf "${lib_target_dir}" || {
      bth_error "Failed to remove existing ${lib_name} installation."
      return 1
    }
  fi

  # Clone the repository
  bth_debug "Cloning ${lib_name} from ${lib_repo}..."
  git clone --depth 1 "${lib_repo}" "${BTH_TEMP_DIR}/${lib_name}" &>> "${BTH_LOG_FILE}" || {
    bth_error "Failed to clone ${lib_name} repository."
    return 1
  }

  # Move to final location
  bth_debug "Moving ${lib_name} to final location..."
  mv "${BTH_TEMP_DIR}/${lib_name}" "${lib_target_dir}" || {
    bth_error "Failed to install ${lib_name} to ${lib_target_dir}."
    return 1
  }

  # Verify installation
  if [[ ! -f "${lib_target_dir}/load.bash" && ! -f "${lib_target_dir}/load" ]]; then
    bth_error "Installation of ${lib_name} appears to be invalid. Missing load file."
    return 1
  fi

  bth_info "Successfully installed ${lib_name}."
  return 0
}

# Main function
bth_main() {
  local return_code=0

  bth_info "Starting BATS helper libraries installation..."

  # Check dependencies
  bth_check_dependencies || {
    bth_error "Missing dependencies. Aborting installation."
    return 1
  }

  # Create necessary directories
  bth_create_directories || {
    bth_error "Failed to create directories. Aborting installation."
    return 1
  }

  # Install each helper library
  for lib_name in "${!BTH_LIBS[@]}"; do
    bth_install_helper "${lib_name}" "${BTH_LIBS[${lib_name}]}" || {
      bth_error "Failed to install ${lib_name}."
      return_code=1
    }
  done

  # Final message
  if [[ ${return_code} -eq 0 ]]; then
    bth_info "BATS helper libraries installation completed successfully!"
    bth_info "You can now run your tests with: bats tests/battery_guardian.bats"
  else
    bth_error "BATS helper libraries installation completed with errors."
    bth_error "Please check the log file for details: ${BTH_LOG_FILE}"
  fi

  return ${return_code}
}

# Set up trap for cleanup
trap bth_cleanup EXIT

# Run main function
bth_main
exit $?