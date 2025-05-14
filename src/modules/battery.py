#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring and management tool.

Battery functions module.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import glob
from pathlib import Path
from typing import Optional, Tuple

from .log import get_logger
from .upower import check_upower_availability, get_battery_status_upower

# Initialize logger
logger = get_logger(__name__)

# Global cache for battery path
BATTERY_PATH: Optional[str] = None

# Flag to track if UPower is available
UPOWER_AVAILABLE = check_upower_availability()

if UPOWER_AVAILABLE:
    logger.info("UPower service detected and will be used for battery monitoring")


def check_battery_exists() -> bool:
    """
    Check if a battery exists in the system.

    Returns:
        True if battery exists, False otherwise
    """
    # Check if we already found a battery
    global BATTERY_PATH
    if BATTERY_PATH and Path(BATTERY_PATH, "capacity").is_file():
        return True

    # Look for any battery in /sys/class/power_supply
    bat_paths = glob.glob("/sys/class/power_supply/BAT*")
    for bat in bat_paths:
        capacity_file = Path(bat, "capacity")
        if capacity_file.is_file():
            try:
                with open(capacity_file, "r") as f:
                    # Just check if we can read it
                    capacity = f.read().strip()
                    if capacity and capacity.isdigit():
                        BATTERY_PATH = bat
                        logger.info(f"Found working battery at {BATTERY_PATH}")
                        return True
            except (IOError, OSError) as e:
                logger.warning(f"Failed to read battery capacity: {e}")

    logger.error("No battery found in the system")
    return False


def check_battery_status() -> Tuple[int, str]:
    """
    Get current battery percentage and AC status.

    Returns:
        Tuple of (battery_percentage, ac_status)
        where ac_status is one of "Connected", "Disconnected", "Unknown"
    """
    # Try UPower first if available
    if UPOWER_AVAILABLE:
        try:
            result = get_battery_status_upower()
            if result is not None:
                percent, ac_status = result
                return percent, ac_status
        except Exception as e:
            logger.warning(f"Failed to get battery status from UPower: {e}")

    # Fall back to sysfs methods
    percent = get_battery_percentage()
    ac_status = get_ac_status()

    return percent, ac_status


def get_battery_percentage() -> int:
    """
    Get current battery percentage.

    Returns:
        Current battery percentage (0-100)
    """
    global BATTERY_PATH

    # First try the more specific check using our previously found battery
    if BATTERY_PATH and Path(BATTERY_PATH, "capacity").is_file():
        try:
            with open(Path(BATTERY_PATH, "capacity"), "r") as f:
                percent = f.read().strip()
                if percent and percent.isdigit():
                    return int(percent)
        except (IOError, OSError) as e:
            logger.warning(f"Failed to read from cached battery path: {e}")

    # Look for any battery
    bat_paths = glob.glob("/sys/class/power_supply/BAT*")
    for bat in bat_paths:
        try:
            with open(Path(bat, "capacity"), "r") as f:
                percent = f.read().strip()
                if percent and percent.isdigit():
                    BATTERY_PATH = bat  # Cache the path
                    return int(percent)
        except (IOError, OSError):
            continue

    # If we get here, we failed to read the battery percentage
    logger.error("Failed to read battery percentage")
    return 0


def get_ac_status() -> str:
    """
    Check if AC power is connected.

    Returns:
        String indicating power status: "Connected", "Disconnected", or "Unknown"
    """
    # Try common AC adapter locations
    ac_paths = glob.glob("/sys/class/power_supply/AC*") + glob.glob(
        "/sys/class/power_supply/ACAD*"
    )

    for ac_path in ac_paths:
        online_file = Path(ac_path, "online")
        if online_file.is_file():
            try:
                with open(online_file, "r") as f:
                    status = f.read().strip()
                    if status == "1":
                        return "Connected"
                    elif status == "0":
                        return "Disconnected"
            except (IOError, OSError) as e:
                logger.warning(f"Failed to read AC status: {e}")

    # If no AC adapter found, try to infer from battery status
    if BATTERY_PATH:
        status_file = Path(BATTERY_PATH, "status")
        if status_file.is_file():
            try:
                with open(status_file, "r") as f:
                    status = f.read().strip().lower()
                    if status == "charging" or status == "full":
                        return "Connected"
                    elif status == "discharging":
                        return "Disconnected"
            except (IOError, OSError) as e:
                logger.warning(f"Failed to read battery status: {e}")

    return "Unknown"


def get_battery_discharge_rate() -> Optional[float]:
    """
    Get the current battery discharge rate in watts, if available.

    Returns:
        Discharge rate in watts or None if not available
    """
    if not BATTERY_PATH:
        return None

    # Try to read current power draw
    try:
        # Different paths depending on kernel/hardware
        power_paths = [
            Path(BATTERY_PATH, "power_now"),
            Path(BATTERY_PATH, "current_now"),
            Path(BATTERY_PATH, "energy_now"),
        ]

        for path in power_paths:
            if path.is_file():
                with open(path, "r") as f:
                    value = f.read().strip()
                    if value and value.isdigit():
                        # Convert from micro-watts or micro-amps to watts
                        return float(value) / 1000000
    except (IOError, OSError, ValueError) as e:
        logger.debug(f"Failed to read battery discharge rate: {e}")

    return None
