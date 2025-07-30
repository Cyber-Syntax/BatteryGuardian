#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tests for the BatteryGuardian battery_monitor module.

This test suite verifies the functionality of the optimized battery monitoring system
that uses file descriptors for improved performance.
"""

import os
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from unittest.mock import MagicMock, patch

import pytest

from batteryguardian.modules.battery_monitor import (
    BatteryMonitor,
    get_battery_monitor,
    get_battery_percentage,
    get_ac_status,
    get_battery_status,
)


class TestBatteryMonitor(unittest.TestCase):
    """Test cases for the BatteryMonitor class."""

    @patch("glob.glob")
    @patch("pathlib.Path.is_file")
    @patch("builtins.open")
    def test_initialization(self, mock_open: MagicMock, mock_is_file: MagicMock,
                           mock_glob: MagicMock) -> None:
        """Test that the BatteryMonitor initializes correctly."""
        # Mock battery paths
        mock_glob.side_effect = lambda pattern: {
            "/sys/class/power_supply/BAT*": ["/sys/class/power_supply/BAT0"],
            "/sys/class/power_supply/AC*": ["/sys/class/power_supply/AC"],
            "/sys/class/power_supply/ACAD*": [],
            "/sys/class/power_supply/ADP*": [],
        }.get(pattern, [])
        
        # Mock file existence
        mock_is_file.return_value = True
        
        # Mock file descriptors
        mock_fd = MagicMock()
        mock_open.return_value = mock_fd
        
        # Create monitor
        monitor = BatteryMonitor()
        
        # Verify initialization
        self.assertIsNotNone(monitor._capacity_fd)
        self.assertIsNotNone(monitor._status_fd)
        self.assertIsNotNone(monitor._ac_online_fd)
        self.assertEqual(monitor._battery_path, "/sys/class/power_supply/BAT0")
        self.assertEqual(monitor._ac_adapter_path, "/sys/class/power_supply/AC")

    @patch("glob.glob")
    @patch("pathlib.Path.is_file")
    @patch("builtins.open")
    def test_get_battery_percentage(self, mock_open: MagicMock, mock_is_file: MagicMock,
                                   mock_glob: MagicMock) -> None:
        """Test reading battery percentage."""
        # Setup mocks
        mock_glob.side_effect = lambda pattern: {
            "/sys/class/power_supply/BAT*": ["/sys/class/power_supply/BAT0"],
        }.get(pattern, [])
        mock_is_file.return_value = True
        
        # Mock file descriptor with battery percentage
        mock_fd = MagicMock()
        mock_fd.read.return_value = "75\n"
        mock_open.return_value = mock_fd
        
        # Create monitor
        monitor = BatteryMonitor()
        
        # Test getting battery percentage
        percentage = monitor.get_battery_percentage()
        self.assertEqual(percentage, 75)
        
        # Verify file was seeked to beginning
        mock_fd.seek.assert_called_with(0)

    @patch("glob.glob")
    @patch("pathlib.Path.is_file")
    @patch("builtins.open")
    def test_get_ac_status(self, mock_open: MagicMock, mock_is_file: MagicMock,
                          mock_glob: MagicMock) -> None:
        """Test reading AC status."""
        # Setup mocks
        mock_glob.side_effect = lambda pattern: {
            "/sys/class/power_supply/BAT*": ["/sys/class/power_supply/BAT0"],
            "/sys/class/power_supply/AC*": ["/sys/class/power_supply/AC"],
        }.get(pattern, [])
        mock_is_file.return_value = True
        
        # Mock file descriptor with AC status
        mock_fd_ac = MagicMock()
        mock_fd_ac.read.return_value = "1\n"  # AC connected
        
        # Mock file descriptor with battery status
        mock_fd_bat = MagicMock()
        mock_fd_bat.read.return_value = "Discharging\n"
        
        # Return different mock file descriptors based on file path
        def mock_open_side_effect(file, *args, **kwargs):
            if str(file).endswith("online"):
                return mock_fd_ac
            return mock_fd_bat
        
        mock_open.side_effect = mock_open_side_effect
        
        # Create monitor
        monitor = BatteryMonitor()
        
        # Test getting AC status
        status = monitor.get_ac_status()
        self.assertEqual(status, "Connected")
        
        # Verify file was seeked to beginning
        mock_fd_ac.seek.assert_called_with(0)

    @patch("glob.glob")
    @patch("pathlib.Path.is_file")
    @patch("builtins.open")
    def test_file_reopen(self, mock_open: MagicMock, mock_is_file: MagicMock,
                        mock_glob: MagicMock) -> None:
        """Test that files are reopened if they fail."""
        # Setup mocks
        mock_glob.side_effect = lambda pattern: {
            "/sys/class/power_supply/BAT*": ["/sys/class/power_supply/BAT0"],
        }.get(pattern, [])
        mock_is_file.return_value = True
        
        # First create a normal file descriptor
        mock_fd = MagicMock()
        mock_fd.read.return_value = "80\n"
        mock_open.return_value = mock_fd
        
        # Create monitor
        monitor = BatteryMonitor()
        
        # Make the file descriptor raise an error on the second read
        mock_fd.seek.side_effect = [None, IOError("File descriptor closed")]
        
        # First call should succeed
        percentage = monitor.get_battery_percentage()
        self.assertEqual(percentage, 80)
        
        # Second call should trigger a reopen
        mock_fd.read.return_value = "85\n"  # Updated value after reopen
        
        # Test that exception is handled and file is reopened
        with patch.object(monitor, "_reopen_battery_files") as mock_reopen:
            monitor.get_battery_percentage()
            mock_reopen.assert_called_once()

    def test_singleton_instance(self) -> None:
        """Test that get_battery_monitor returns a singleton instance."""
        monitor1 = get_battery_monitor()
        monitor2 = get_battery_monitor()
        
        # Verify it's the same instance
        self.assertIs(monitor1, monitor2)


class TestBatteryModuleFunctions(unittest.TestCase):
    """Test the module-level wrapper functions."""
    
    @patch("batteryguardian.modules.battery_monitor.get_battery_monitor")
    def test_get_battery_percentage(self, mock_get_monitor: MagicMock) -> None:
        """Test the get_battery_percentage function."""
        mock_monitor = MagicMock()
        mock_monitor.get_battery_percentage.return_value = 42
        mock_get_monitor.return_value = mock_monitor
        
        percentage = get_battery_percentage()
        self.assertEqual(percentage, 42)
        mock_monitor.get_battery_percentage.assert_called_once()

    @patch("batteryguardian.modules.battery_monitor.get_battery_monitor")
    def test_get_ac_status(self, mock_get_monitor: MagicMock) -> None:
        """Test the get_ac_status function."""
        mock_monitor = MagicMock()
        mock_monitor.get_ac_status.return_value = "Connected"
        mock_get_monitor.return_value = mock_monitor
        
        status = get_ac_status()
        self.assertEqual(status, "Connected")
        mock_monitor.get_ac_status.assert_called_once()

    @patch("batteryguardian.modules.battery_monitor.get_battery_monitor")
    def test_get_battery_status(self, mock_get_monitor: MagicMock) -> None:
        """Test the get_battery_status function."""
        mock_monitor = MagicMock()
        mock_monitor.get_battery_status.return_value = (87, "Connected")
        mock_get_monitor.return_value = mock_monitor
        
        battery_status = get_battery_status()
        self.assertEqual(battery_status, (87, "Connected"))
        mock_monitor.get_battery_status.assert_called_once()


if __name__ == "__main__":
    pytest.main(["-xvs", __file__])
