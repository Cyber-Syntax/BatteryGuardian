#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring and management tool.

Brightness control functions.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import glob
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, Optional

from .log import get_logger
from .utils import check_command_exists

# Initialize logger
logger = get_logger(__name__)

# Global state
BRIGHTNESS_CONTROL_METHOD: Optional[str] = None
BACKLIGHT_PATH: Optional[str] = None


def adjust_brightness(
    battery_percent: int, ac_status: str, config: Dict[str, Any]
) -> bool:
    """
    Adjust screen brightness based on battery level and AC status.

    Args:
        battery_percent: Current battery percentage
        ac_status: Current AC power status
        config: Application configuration

    Returns:
        True if brightness was successfully adjusted, False otherwise
    """
    if not config.get("brightness_control_enabled", True):
        logger.debug("Brightness control is disabled in configuration")
        return False

    # Determine target brightness level
    target_brightness = get_target_brightness(battery_percent, ac_status, config)

    # Apply the brightness level
    return set_brightness(target_brightness)


def get_target_brightness(
    battery_percent: int, ac_status: str, config: Dict[str, Any]
) -> int:
    """
    Calculate target brightness level based on battery and power status.

    Args:
        battery_percent: Current battery percentage
        ac_status: Current AC power status
        config: Application configuration

    Returns:
        Target brightness level (percentage)
    """
    # When on AC, use max brightness
    if ac_status == "Connected":
        return config.get("brightness_max", 100)

    # When on battery, adjust brightness based on battery level
    thresholds = [
        (
            config.get("battery_very_high_threshold", 85),
            config.get("brightness_very_high", 95),
        ),
        (config.get("battery_high_threshold", 70), config.get("brightness_high", 85)),
        (
            config.get("battery_medium_high_threshold", 60),
            config.get("brightness_medium_high", 70),
        ),
        (
            config.get("battery_medium_threshold", 50),
            config.get("brightness_medium", 60),
        ),
        (
            config.get("battery_medium_low_threshold", 30),
            config.get("brightness_medium_low", 45),
        ),
        (config.get("battery_low_threshold", 20), config.get("brightness_low", 35)),
        (config.get("critical_threshold", 10), config.get("brightness_very_low", 25)),
    ]

    # Default to critical brightness
    brightness = config.get("brightness_critical", 15)

    # Find appropriate brightness level
    for threshold, value in thresholds:
        if battery_percent >= threshold:
            brightness = value
            break

    return brightness


def get_brightness() -> int:
    """
    Get current screen brightness level.

    Returns:
        Current brightness level as percentage (0-100)
    """
    method = detect_brightness_control_method()

    if method == "brightnessctl":
        try:
            output = subprocess.check_output(
                ["brightnessctl", "info", "-m"], universal_newlines=True
            ).strip()
            # Parse output like "10,255,5%"
            parts = output.split(",")
            if len(parts) >= 3 and parts[2].endswith("%"):
                return int(parts[2].rstrip("%"))
        except (subprocess.SubprocessError, ValueError, IndexError) as e:
            logger.warning(f"Failed to get brightness with brightnessctl: {e}")

    elif method == "light":
        try:
            output = subprocess.check_output(
                ["light", "-G"], universal_newlines=True
            ).strip()
            return round(float(output))
        except (subprocess.SubprocessError, ValueError) as e:
            logger.warning(f"Failed to get brightness with light: {e}")

    elif method == "xbacklight":
        try:
            output = subprocess.check_output(
                ["xbacklight", "-get"], universal_newlines=True
            ).strip()
            return round(float(output))
        except (subprocess.SubprocessError, ValueError) as e:
            logger.warning(f"Failed to get brightness with xbacklight: {e}")

    elif method == "sysfs":
        try:
            backlight = get_backlight_path()
            if backlight:
                max_file = Path(backlight, "max_brightness")
                current_file = Path(backlight, "brightness")

                with open(max_file, "r") as f:
                    max_brightness = int(f.read().strip())

                with open(current_file, "r") as f:
                    current_brightness = int(f.read().strip())

                return round((current_brightness / max_brightness) * 100)
        except (IOError, OSError, ValueError) as e:
            logger.warning(f"Failed to get brightness from sysfs: {e}")

    logger.error("Failed to get current brightness level")
    return 50  # Return a default value


def set_brightness(level: int) -> bool:
    """
    Set screen brightness to the specified level.

    Args:
        level: Target brightness level (percentage 0-100)

    Returns:
        True if brightness was set successfully, False otherwise
    """
    # Ensure level is within valid range
    level = max(0, min(100, level))

    method = detect_brightness_control_method()
    success = False

    if method == "brightnessctl":
        try:
            subprocess.run(["brightnessctl", "set", f"{level}%", "-q"], check=True)
            logger.debug(f"Set brightness to {level}% using brightnessctl")
            success = True
        except subprocess.SubprocessError as e:
            logger.warning(f"Failed to set brightness with brightnessctl: {e}")

    elif method == "light":
        try:
            subprocess.run(["light", "-S", str(level)], check=True)
            logger.debug(f"Set brightness to {level}% using light")
            success = True
        except subprocess.SubprocessError as e:
            logger.warning(f"Failed to set brightness with light: {e}")

    elif method == "xbacklight":
        try:
            subprocess.run(["xbacklight", "-set", str(level)], check=True)
            logger.debug(f"Set brightness to {level}% using xbacklight")
            success = True
        except subprocess.SubprocessError as e:
            logger.warning(f"Failed to set brightness with xbacklight: {e}")

    elif method == "sysfs":
        try:
            backlight = get_backlight_path()
            if backlight:
                max_file = Path(backlight, "max_brightness")
                current_file = Path(backlight, "brightness")

                with open(max_file, "r") as f:
                    max_brightness = int(f.read().strip())

                # Calculate the raw brightness value
                raw_brightness = round((level / 100) * max_brightness)

                # Check if we have permission to write
                if os.access(current_file, os.W_OK):
                    with open(current_file, "w") as f:
                        f.write(str(raw_brightness))
                    logger.debug(f"Set brightness to {level}% using sysfs")
                    success = True
                else:
                    # Try with sudo if available
                    try:
                        subprocess.run(
                            [
                                "sudo",
                                "-n",
                                "sh",
                                "-c",
                                f"echo {raw_brightness} > {current_file}",
                            ],
                            check=True,
                        )
                        logger.debug(f"Set brightness to {level}% using sudo and sysfs")
                        success = True
                    except subprocess.SubprocessError as e:
                        logger.error(f"Failed to set brightness with sysfs: {e}")
        except (IOError, OSError, ValueError) as e:
            logger.warning(f"Failed to set brightness with sysfs: {e}")

    if not success:
        logger.error(f"Failed to set brightness to {level}%")

    return success


def detect_brightness_control_method() -> str:
    """
    Detect available brightness control method.

    Returns:
        Method to use for controlling brightness:
        "brightnessctl", "light", "xbacklight", "sysfs", or "none"
    """
    global BRIGHTNESS_CONTROL_METHOD

    # Return cached value if available
    if BRIGHTNESS_CONTROL_METHOD:
        return BRIGHTNESS_CONTROL_METHOD

    # Check for tools in priority order
    if check_command_exists("brightnessctl"):
        BRIGHTNESS_CONTROL_METHOD = "brightnessctl"
        return BRIGHTNESS_CONTROL_METHOD

    if check_command_exists("light"):
        BRIGHTNESS_CONTROL_METHOD = "light"
        return BRIGHTNESS_CONTROL_METHOD

    if check_command_exists("xbacklight"):
        BRIGHTNESS_CONTROL_METHOD = "xbacklight"
        return BRIGHTNESS_CONTROL_METHOD

    # Fallback to sysfs if a valid backlight device exists
    if get_backlight_path():
        BRIGHTNESS_CONTROL_METHOD = "sysfs"
        return BRIGHTNESS_CONTROL_METHOD

    BRIGHTNESS_CONTROL_METHOD = "none"
    return BRIGHTNESS_CONTROL_METHOD


def get_backlight_path() -> Optional[str]:
    """
    Find a valid backlight device in sysfs.

    Returns:
        Path to backlight device or None if not found
    """
    global BACKLIGHT_PATH

    # Return cached path if available
    if BACKLIGHT_PATH and Path(BACKLIGHT_PATH).exists():
        return BACKLIGHT_PATH

    # Check for backlight devices
    backlight_dirs = glob.glob("/sys/class/backlight/*")

    for backlight in backlight_dirs:
        max_file = Path(backlight, "max_brightness")
        current_file = Path(backlight, "brightness")

        if max_file.is_file() and current_file.is_file():
            # Prefer Intel and AMD backlights
            if "intel" in backlight.lower() or "amd" in backlight.lower():
                BACKLIGHT_PATH = backlight
                return BACKLIGHT_PATH

    # If no preferred device found, use the first available
    if backlight_dirs:
        BACKLIGHT_PATH = backlight_dirs[0]
        return BACKLIGHT_PATH

    return None
