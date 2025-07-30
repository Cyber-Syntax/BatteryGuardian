#!/usr/bin/env bash
#
# BatteryGuardian Deployment Script
# ----------------------------------------
# Deploys BatteryGuardian scripts and configurations to XDG base directories
# Author: Cyber-Syntax
# License: BSD 3-Clause License

# Ensure script exits on errors, undefined variables, and pipe failures
set -o errexit -o nounset -o pipefail

# Colors for output
readonly BG_RED='\033[0;31m'
readonly BG_GREEN='\033[0;32m'
readonly BG_YELLOW='\033[0;33m'
readonly BG_BLUE='\033[0;34m'
readonly BG_NC='\033[0m' # No Color

# Default locations based on XDG Base Directory Specification
readonly XDG_BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
readonly XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# Repo and installation directories
# Get the absolute path to the repository directory
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
BG_REPO_DIR="$(pwd)"
readonly BG_REPO_DIR
cd - > /dev/null || exit 1
readonly BG_INSTALL_DIR="${XDG_DATA_HOME}/battery-guardian"
readonly BG_BIN_DIR="${XDG_BIN_HOME}"
readonly BG_CONFIG_DIR="${XDG_CONFIG_HOME}/battery-guardian"
readonly BG_STATE_DIR="${XDG_STATE_HOME}/battery-guardian"

# Define script directories and their installation paths
declare -A BG_SCRIPT_DIRS
BG_SCRIPT_DIRS["src"]="${BG_INSTALL_DIR}/src"
BG_SCRIPT_DIRS["configs"]="${BG_CONFIG_DIR}"

# Paths for runtime state
readonly BG_LOGS_DIR="${BG_STATE_DIR}/logs"

# Print usage information
bg_print_usage() {
  echo -e "${BG_BLUE}BatteryGuardian - Deployment Script${BG_NC}"
  echo
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo "  -h, --help        Show this help message"
  echo "  -d, --dev         Install from current directory (development mode)"
  echo "  -m, --main        Install from main branch (default)"
  echo "  -f, --force       Force installation (overwrite existing files)"
  echo "  -v, --verbose     Verbose output"
  echo "  -t, --target DIR  Specify custom installation directory"
  echo
  echo "Example:"
  echo "  $0 --dev          # Install from current directory"
  echo "  $0 --main         # Install from main branch"
  echo "  $0 --target ~/scripts # Install to custom directory"
}

# Log messages with colors based on type
bg_log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  case "$level" in
    "DEBUG")
      if [[ "${BG_VERBOSE}" == "true" ]]; then
        echo -e "${timestamp} ${BG_BLUE}[DEBUG]${BG_NC} $message"
      fi
      ;;
    "INFO")
      if [[ "${BG_VERBOSE}" == "true" ]]; then
        echo -e "${timestamp} ${BG_BLUE}[INFO]${BG_NC} $message"
      fi
      ;;
    "SUCCESS")
      echo -e "${timestamp} ${BG_GREEN}[SUCCESS]${BG_NC} $message"
      ;;
    "WARNING")
      echo -e "${timestamp} ${BG_YELLOW}[WARNING]${BG_NC} $message"
      ;;
    "ERROR")
      echo -e "${timestamp} ${BG_RED}[ERROR]${BG_NC} $message" >&2
      ;;
  esac
}

# Log level wrappers
bg_debug() { bg_log "DEBUG" "$1"; }
bg_info() { bg_log "INFO" "$1"; }
bg_success() { bg_log "SUCCESS" "$1"; }
bg_warn() { bg_log "WARNING" "$1"; }
bg_error() { bg_log "ERROR" "$1"; }

# Check if a command exists
bg_command_exists() {
  command -v "$1" &> /dev/null
}

# Check required dependencies are installed
bg_check_dependencies() {
  local missing_deps=false

  for cmd in git cp chmod; do
    if ! bg_command_exists "$cmd"; then
      bg_error "Required command not found: $cmd"
      missing_deps=true
    fi
  done

  if [[ "$missing_deps" == "true" ]]; then
    bg_error "Missing required dependencies. Please install them and try again."
    return 1
  fi

  return 0
}

# Create directory if it doesn't exist
bg_ensure_dir_exists() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    bg_debug "Creating directory: $dir"
    mkdir -p "$dir" || {
      bg_error "Failed to create directory: $dir"
      return 1
    }
  fi

  return 0
}

# Copy script with proper permissions
bg_copy_script() {
  local src="$1"
  local dest="$2"
  local base_dest_dir

  # Validate paths - prevent directory traversal
  if [[ "$src" == *".."* ]] || [[ "$dest" == *".."* ]]; then
    bg_error "Path contains forbidden pattern: .."
    return 1
  fi

  base_dest_dir="$(dirname "$dest")"

  bg_ensure_dir_exists "$base_dest_dir" || return 1

  if [[ -f "$dest" && "${BG_FORCE}" != "true" ]]; then
    bg_warn "File already exists: $dest (use --force to overwrite)"
    return 0
  fi

  cp "$src" "$dest" || {
    bg_error "Failed to copy $src to $dest"
    return 1
  }

  if [[ "$src" == *.sh ]]; then
    chmod +x "$dest" || {
      bg_error "Failed to set executable permission on $dest"
      return 1
    }
  fi

  bg_info "Installed: $dest"
  return 0
}

# Create symbolic links in bin directory
bg_create_symlinks() {
  bg_ensure_dir_exists "$BG_BIN_DIR" || return 1

  # Find all executable scripts
  find "$BG_INSTALL_DIR" -type f -name "*.sh" | while read -r script; do
    local script_name
    local link_path

    script_name="$(basename "$script" .sh)"
    link_path="$BG_BIN_DIR/$script_name"

    # Skip if link exists and not forcing
    if [[ -L "$link_path" || -e "$link_path" ]] && [[ "${BG_FORCE}" != "true" ]]; then
      bg_warn "Symlink already exists: $link_path (use --force to overwrite)"
      continue
    fi

    # Remove existing symlink or file if it exists
    if [[ -L "$link_path" || -e "$link_path" ]] && [[ "${BG_FORCE}" == "true" ]]; then
      rm -f "$link_path" || {
        bg_error "Failed to remove existing link: $link_path"
        continue
      }
    fi

    ln -sf "$script" "$link_path" || {
      bg_error "Failed to create symlink: $link_path -> $script"
      continue
    }

    bg_info "Created symlink: $link_path -> $script"
  done
}

# Install from current directory (development mode)
bg_install_from_dev() {
  bg_info "Installing from development directory..."

  # Create installation directories
  bg_ensure_dir_exists "$BG_INSTALL_DIR"
  bg_ensure_dir_exists "$BG_CONFIG_DIR"
  bg_ensure_dir_exists "$BG_STATE_DIR"
  bg_ensure_dir_exists "$BG_LOGS_DIR"

  # Install scripts by category
  for dir in "${!BG_SCRIPT_DIRS[@]}"; do
    local source_dir="${BG_REPO_DIR}/${dir}"
    local target_dir="${BG_SCRIPT_DIRS[$dir]}"

    if [[ -d "$source_dir" ]]; then
      bg_ensure_dir_exists "$target_dir"

      # Find all shell scripts in this category
      find "$source_dir" -type f -name "*.sh" | while read -r script; do
        local script_name
        script_name="$(basename "$script")"
        bg_copy_script "$script" "${target_dir}/${script_name}"
      done
    else
      bg_warn "Directory not found: $source_dir"
    fi
  done

  # Create symlinks for easy access
  bg_create_symlinks

  bg_success "Development installation complete!"
  bg_info "Scripts installed to: $BG_INSTALL_DIR"
  bg_info "Symlinks created in: $BG_BIN_DIR"
}

# Install from main branch by cloning directly to the installation directory
bg_install_from_main() {
  bg_info "Installing from main branch..."

  # Check if git is available
  if ! bg_command_exists git; then
    bg_error "Git is not installed. Please install git first."
    exit 1
  fi

  # Clean installation directory if it exists and force is enabled
  if [[ -d "$BG_INSTALL_DIR" ]]; then
    if [[ "${BG_FORCE}" == "true" ]]; then
      bg_info "Removing existing installation directory..."
      rm -rf "$BG_INSTALL_DIR"
    else
      bg_warn "Installation directory already exists: $BG_INSTALL_DIR"
      bg_warn "Use --force to reinstall from main branch"
      exit 1
    fi
  fi

  # Create parent directories
  bg_ensure_dir_exists "$(dirname "$BG_INSTALL_DIR")"

  # Clone directly to the installation directory
  local repo_url="https://github.com/cyber-syntax/BatteryGuardian.git"
  bg_info "Cloning repository to: $BG_INSTALL_DIR"

  if ! git clone --depth 1 --branch main "$repo_url" "$BG_INSTALL_DIR"; then
    bg_error "Failed to clone repository."
    exit 1
  fi

  # Reorganize files if needed - if the repository structure doesn't match our expected structure
  # Check if we have the expected directory structure
  local has_expected_structure=true
  for dir in "${!BG_SCRIPT_DIRS[@]}"; do
    if [[ ! -d "$BG_INSTALL_DIR/$dir" ]]; then
      has_expected_structure=false
      break
    fi
  done

  if [[ "$has_expected_structure" == "false" ]]; then
    bg_info "Repository structure differs from expected. Reorganizing..."

    # Create a temporary directory for reorganization
    local temp_dir
    temp_dir="$(mktemp -d)"

    # Look for script files in the repository and move them to the appropriate category
    find "$BG_INSTALL_DIR" -type f -name "*.sh" | while read -r script; do
      local script_name
      script_name="$(basename "$script")"
      local script_path
      script_path="$(dirname "$script")"

      # Determine script category based on BatteryGuardian structure
      local category="src"

      # Check if it's a config file
      if [[ "$script_name" == "defaults.sh" || "$script_path" == *"/configs"* ]]; then
        category="configs"
      # Check if it's a test file
      elif [[ "$script_name" == *"test"* || "$script_name" == *".bats" || "$script_path" == *"/tests"* ]]; then
        category="tests"
      fi

      # Create category directory in temp dir
      bg_ensure_dir_exists "$temp_dir/$category"

      # Copy script to temp directory
      cp "$script" "$temp_dir/$category/"
      chmod +x "$temp_dir/$category/$script_name"
    done

    # Clean installation directory except .git
    find "$BG_INSTALL_DIR" -mindepth 1 -not -path "$BG_INSTALL_DIR/.git*" -delete

    # Move reorganized files back to installation directory
    cp -r "$temp_dir/"* "$BG_INSTALL_DIR/"

    # Clean up
    rm -rf "$temp_dir"
  fi

  # Create necessary directories
  bg_ensure_dir_exists "$BG_CONFIG_DIR"
  bg_ensure_dir_exists "$BG_STATE_DIR"
  bg_ensure_dir_exists "$BG_LOGS_DIR"

  # Create symlinks for easy access
  bg_create_symlinks

  bg_success "Main branch installation complete!"
  bg_info "Scripts installed to: $BG_INSTALL_DIR"
  bg_info "Symlinks created in: $BG_BIN_DIR"
}

# Parse command-line arguments
BG_MODE="main"  # Default mode is main branch
BG_FORCE="false"
BG_VERBOSE="false"
BG_CUSTOM_INSTALL_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      bg_print_usage
      exit 0
      ;;
    -d|--dev)
      BG_MODE="dev"
      shift
      ;;
    -m|--main)
      BG_MODE="main"
      shift
      ;;
    -f|--force)
      BG_FORCE="true"
      shift
      ;;
    -v|--verbose)
      BG_VERBOSE="true"
      shift
      ;;
    -t|--target)
      if [[ -n "$2" ]]; then
        BG_CUSTOM_INSTALL_DIR="$2"
        BG_INSTALL_DIR="$BG_CUSTOM_INSTALL_DIR"
        shift 2
      else
        bg_error "Option --target requires a directory argument."
        exit 1
      fi
      ;;
    *)
      bg_error "Unknown option: $1"
      bg_print_usage
      exit 1
      ;;
  esac
done

# Run installation based on selected mode
if [[ "$BG_MODE" == "dev" ]]; then
  bg_install_from_dev
else
  bg_install_from_main
fi

exit 0