#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Dependency installer script.

This script helps users install optional dependencies for enhanced features.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import argparse
import subprocess
import sys
from pathlib import Path

# Define dependency groups
DEPENDENCY_GROUPS = {
    "core": [
        "PyYAML>=6.0",
    ],
    "events": [
        "pyudev>=0.22.0",
        "dbus-python>=1.2.16",
        "PyGObject>=3.38.0",
    ],
    "all": [
        "PyYAML>=6.0",
        "pyudev>=0.22.0",
        "dbus-python>=1.2.16",
        "PyGObject>=3.38.0",
    ],
}

# Define system package mapping for common distributions
SYSTEM_PACKAGES = {
    "debian": {
        "pyudev": "python3-pyudev",
        "dbus-python": "python3-dbus",
        "PyGObject": "python3-gi",
        "acpi": "acpid",
    },
    "fedora": {
        "pyudev": "python3-pyudev",
        "dbus-python": "python3-dbus",
        "PyGObject": "python3-gobject",
        "acpi": "acpid",
    },
    "arch": {
        "pyudev": "python-pyudev",
        "dbus-python": "python-dbus",
        "PyGObject": "python-gobject",
        "acpi": "acpid",
    },
    "opensuse": {
        "pyudev": "python3-pyudev",
        "dbus-python": "python3-dbus-python",
        "PyGObject": "python3-gobject",
        "acpi": "acpid",
    },
}


def detect_distribution():
    """
    Attempt to detect the Linux distribution.

    Returns:
        Distribution family name or None if not detected
    """
    # Check for os-release file (standard on most modern distributions)
    os_release = Path("/etc/os-release")
    if os_release.exists():
        try:
            with open(os_release, "r") as f:
                content = f.read().lower()

                # Check for common distribution identifiers
                if "debian" in content or "ubuntu" in content or "mint" in content:
                    return "debian"
                elif "fedora" in content or "rhel" in content or "centos" in content:
                    return "fedora"
                elif "arch" in content:
                    return "arch"
                elif "opensuse" in content or "suse" in content:
                    return "opensuse"
        except Exception:
            pass

    # Alternative detection methods
    if Path("/etc/debian_version").exists():
        return "debian"
    elif Path("/etc/fedora-release").exists():
        return "fedora"
    elif Path("/etc/arch-release").exists():
        return "arch"
    elif Path("/etc/SuSE-release").exists():
        return "opensuse"

    return None


def install_pip_dependencies(dependencies):
    """Install the specified Python dependencies using pip."""
    print(f"Installing Python dependencies: {', '.join(dependencies)}")

    # Check if pip is available
    try:
        subprocess.run(
            [sys.executable, "-m", "pip", "--version"], check=True, capture_output=True
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        print("Error: pip is not available. Please install pip first.")
        return False

    # Install dependencies
    try:
        cmd = [sys.executable, "-m", "pip", "install"] + dependencies
        subprocess.run(cmd, check=True)
        print("Successfully installed Python dependencies.")
        return True
    except subprocess.SubprocessError as e:
        print(f"Error installing Python dependencies: {e}")
        return False


def install_system_packages(packages, distro):
    """Install the specified system packages using the appropriate package manager."""
    if distro not in SYSTEM_PACKAGES:
        print(f"Unsupported distribution: {distro}")
        return False

    # Map to actual system package names
    system_packages = [SYSTEM_PACKAGES[distro].get(pkg, pkg) for pkg in packages]
    print(f"Installing system packages: {', '.join(system_packages)}")

    # Determine the package manager command
    if distro == "debian":
        cmd = ["sudo", "apt-get", "install", "-y"] + system_packages
    elif distro == "fedora":
        cmd = ["sudo", "dnf", "install", "-y"] + system_packages
    elif distro == "arch":
        cmd = ["sudo", "pacman", "-S", "--noconfirm"] + system_packages
    elif distro == "opensuse":
        cmd = ["sudo", "zypper", "install", "-y"] + system_packages
    else:
        print("Unsupported distribution for system package installation")
        return False

    # Install packages
    try:
        subprocess.run(cmd, check=True)
        print("Successfully installed system packages.")
        return True
    except subprocess.SubprocessError as e:
        print(f"Error installing system packages: {e}")
        return False


def main():
    """Main function to handle dependency installation."""
    parser = argparse.ArgumentParser(description="BatteryGuardian dependency installer")
    parser.add_argument(
        "group",
        choices=["core", "events", "all"],
        help="Dependency group to install (core=minimal, events=event monitoring, all=everything)",
    )
    parser.add_argument(
        "--pip-only",
        action="store_true",
        help="Only install Python dependencies via pip, skip system packages",
    )
    parser.add_argument(
        "--system-only",
        action="store_true",
        help="Only install system packages, skip pip dependencies",
    )

    args = parser.parse_args()

    # Get dependencies based on selected group
    pip_dependencies = DEPENDENCY_GROUPS.get(args.group, [])

    # Determine system packages needed
    system_packages = []
    if args.group in ["events", "all"]:
        system_packages = ["acpi"]

    # Detect distribution if needed
    distro = None
    if system_packages and not args.pip_only:
        distro = detect_distribution()
        if not distro:
            print(
                "Warning: Could not detect Linux distribution. Skipping system package installation."
            )
            if not args.system_only:
                print("Proceeding with pip dependencies only.")
            else:
                return 1

    # Install dependencies
    success = True

    if pip_dependencies and not args.system_only:
        success &= install_pip_dependencies(pip_dependencies)

    if system_packages and distro and not args.pip_only:
        success &= install_system_packages(system_packages, distro)

    if success:
        print("\nAll dependencies installed successfully!")
        if args.group in ["events", "all"]:
            print(
                "\nEvent-based monitoring should now be available when you run BatteryGuardian."
            )
            print("This will reduce power consumption compared to the polling method.")
    else:
        print(
            "\nSome dependencies could not be installed. Please check the error messages above."
        )
        print("You can still run BatteryGuardian, but some features may be limited.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
