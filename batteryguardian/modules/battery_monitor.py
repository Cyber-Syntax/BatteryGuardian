#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring with optimized file access.

This module provides a BatteryMonitor class that keeps file descriptors open
for fast battery status checks without repeatedly opening and closing files.

Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import atexit
import glob
from pathlib import Path
from typing import Optional, TextIO, Tuple

from .log import get_logger

# Initialize logger
logger = get_logger(__name__)


class BatteryMonitor:
    """
    Monitor battery status with optimized file access.

    This class keeps file descriptors open for fast access to battery status
    information, avoiding the overhead of repeatedly opening and closing files.
    """

    def __init__(self) -> None:
        """Initialize the battery monitor with open file descriptors."""
        # File descriptors for battery information
        self._capacity_fd: Optional[TextIO] = None
        self._status_fd: Optional[TextIO] = None
        self._ac_online_fd: Optional[TextIO] = None

        # Discovered paths
        self._battery_path: Optional[str] = None
        self._ac_adapter_path: Optional[str] = None

        # Initialize file descriptors
        self._initialize_battery_files()
        self._initialize_ac_adapter_files()

        # Register cleanup handler
        atexit.register(self.close)

    def _initialize_battery_files(self) -> None:
        """Initialize battery file descriptors."""
        # Look for any battery in /sys/class/power_supply
        bat_paths = glob.glob("/sys/class/power_supply/BAT*")
        for bat in bat_paths:
            capacity_path = Path(bat, "capacity")
            status_path = Path(bat, "status")

            if capacity_path.is_file():
                try:
                    self._capacity_fd = open(capacity_path, "r", encoding="utf-8")
                    if status_path.is_file():
                        self._status_fd = open(status_path, "r", encoding="utf-8")

                    self._battery_path = bat
                    logger.info(f"Opened battery files at {bat}")
                    break
                except (IOError, OSError) as e:
                    logger.error(f"Failed to open battery files at {bat}: {e}")
                    continue

    def _initialize_ac_adapter_files(self) -> None:
        """Initialize AC adapter file descriptors."""
        # Try common AC adapter locations
        ac_paths = (
            glob.glob("/sys/class/power_supply/AC*")
            + glob.glob("/sys/class/power_supply/ACAD*")
            + glob.glob("/sys/class/power_supply/ADP*")
        )

        for ac_path in ac_paths:
            online_file = Path(ac_path, "online")
            if online_file.is_file():
                try:
                    self._ac_online_fd = open(online_file, "r", encoding="utf-8")
                    self._ac_adapter_path = ac_path
                    logger.info(f"Opened AC adapter file at {ac_path}")
                    break
                except (IOError, OSError) as e:
                    logger.error(f"Failed to open AC adapter file at {ac_path}: {e}")
                    continue

    def get_battery_percentage(self) -> int:
        """
        Get current battery percentage.

        Returns:
            Current battery percentage (0-100)
        """
        if self._capacity_fd is None:
            logger.error("Battery capacity file not available")
            return 0

        try:
            # Seek to beginning of file to get fresh data
            self._capacity_fd.seek(0)
            percent_str = self._capacity_fd.read().strip()

            if percent_str and percent_str.isdigit():
                return int(percent_str)
            else:
                logger.warning(f"Invalid battery percentage format: '{percent_str}'")
                return 0
        except (IOError, OSError, ValueError) as e:
            logger.error(f"Failed to read battery percentage: {e}")
            # Try to reopen the file
            self._reopen_battery_files()
            return 0

    def get_ac_status(self) -> str:
        """
        Check if AC power is connected.

        Returns:
            String indicating power status: "Connected", "Disconnected", or "Unknown"
        """
        # First try direct AC adapter status
        if self._ac_online_fd is not None:
            try:
                self._ac_online_fd.seek(0)
                status = self._ac_online_fd.read().strip()
                if status == "1":
                    return "Connected"
                elif status == "0":
                    return "Disconnected"
            except (IOError, OSError) as e:
                logger.error(f"Failed to read AC adapter status: {e}")
                # Try to reopen the file
                self._reopen_ac_adapter_files()

        # Fall back to battery status if AC adapter not available
        if self._status_fd is not None:
            try:
                self._status_fd.seek(0)
                status = self._status_fd.read().strip().lower()
                if status == "charging" or status == "full":
                    return "Connected"
                elif status == "discharging":
                    return "Disconnected"
            except (IOError, OSError) as e:
                logger.error(f"Failed to read battery status: {e}")
                # Try to reopen the file
                self._reopen_battery_files()

        return "Unknown"

    def get_battery_status(self) -> Tuple[int, str]:
        """
        Get both battery percentage and AC status in one call.

        Returns:
            Tuple of (battery_percentage, ac_status)
        """
        return self.get_battery_percentage(), self.get_ac_status()

    def _reopen_battery_files(self) -> None:
        """Reopen battery files if they were closed."""
        if self._battery_path:
            capacity_path = Path(self._battery_path, "capacity")
            status_path = Path(self._battery_path, "status")

            # Close existing file descriptors if any
            if self._capacity_fd:
                try:
                    self._capacity_fd.close()
                except (IOError, OSError):
                    pass

            if self._status_fd:
                try:
                    self._status_fd.close()
                except (IOError, OSError):
                    pass

            # Reopen the files
            try:
                if capacity_path.is_file():
                    self._capacity_fd = open(capacity_path, "r", encoding="utf-8")
                if status_path.is_file():
                    self._status_fd = open(status_path, "r", encoding="utf-8")
            except (IOError, OSError) as e:
                logger.error(f"Failed to reopen battery files: {e}")
                self._capacity_fd = None
                self._status_fd = None

    def _reopen_ac_adapter_files(self) -> None:
        """Reopen AC adapter files if they were closed."""
        if self._ac_adapter_path:
            online_file = Path(self._ac_adapter_path, "online")

            # Close existing file descriptor if any
            if self._ac_online_fd:
                try:
                    self._ac_online_fd.close()
                except (IOError, OSError):
                    pass

            # Reopen the file
            try:
                if online_file.is_file():
                    self._ac_online_fd = open(online_file, "r", encoding="utf-8")
            except (IOError, OSError) as e:
                logger.error(f"Failed to reopen AC adapter file: {e}")
                self._ac_online_fd = None

    def close(self) -> None:
        """Close all open file descriptors."""
        for fd in [self._capacity_fd, self._status_fd, self._ac_online_fd]:
            if fd:
                try:
                    fd.close()
                except (IOError, OSError) as e:
                    logger.error(f"Error closing file descriptor: {e}")

        self._capacity_fd = None
        self._status_fd = None
        self._ac_online_fd = None


# Singleton instance for global use
_battery_monitor: Optional[BatteryMonitor] = None


def get_battery_monitor() -> BatteryMonitor:
    """
    Get a singleton instance of BatteryMonitor.

    Returns:
        A BatteryMonitor instance
    """
    global _battery_monitor
    if _battery_monitor is None:
        _battery_monitor = BatteryMonitor()
    return _battery_monitor


def get_battery_percentage() -> int:
    """
    Get battery percentage using the BatteryMonitor.

    Returns:
        Battery percentage (0-100)
    """
    return get_battery_monitor().get_battery_percentage()


def get_ac_status() -> str:
    """
    Get AC status using the BatteryMonitor.

    Returns:
        AC status: "Connected", "Disconnected", or "Unknown"
    """
    return get_battery_monitor().get_ac_status()


def get_battery_status() -> Tuple[int, str]:
    """
    Get battery status using the BatteryMonitor.

    Returns:
        Tuple of (battery_percentage, ac_status)
    """
    return get_battery_monitor().get_battery_status()
