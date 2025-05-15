#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
UPower module test script.

Tests the UPower monitoring module implementation.
"""

import logging
import sys
import threading
import time
import unittest
from unittest import mock

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# Import path setup for testing
sys.path.append("/home/developer/Documents/repository/BatteryGuardian")

# Try to import the UPower module
try:
    from batteryguardian.modules.upower import (
        check_upower_availability,
        get_battery_status_upower,
        initialize_upower_monitoring,
    )
except ImportError as e:
    logger.error(f"Failed to import UPower module: {e}")
    logger.error("Make sure you're running this from the project root directory")
    sys.exit(1)


class TestUPowerModule(unittest.TestCase):
    """Test cases for the UPower monitoring module."""

    def setUp(self):
        """Set up test fixtures."""
        self.state = {"battery_percent": 0, "ac_status": "Unknown"}
        self.event_received = threading.Event()
        self.battery_percent = 0
        self.ac_status = "Unknown"

    def callback_function(self, battery_percent, ac_status):
        """Callback function for UPower events."""
        self.battery_percent = battery_percent
        self.ac_status = ac_status
        self.event_received.set()
        logger.info(f"Received event: battery={battery_percent}%, AC={ac_status}")

    def test_upower_availability(self):
        """Test that we can detect UPower availability."""
        # This test should pass if UPower is available or be skipped if not
        is_available = check_upower_availability()
        if not is_available:
            self.skipTest("UPower is not available on this system")
        self.assertTrue(is_available)

    def test_get_battery_status(self):
        """Test that we can get battery status from UPower."""
        # Skip if UPower is not available
        if not check_upower_availability():
            self.skipTest("UPower is not available on this system")

        # Get battery status
        result = get_battery_status_upower()
        self.assertIsNotNone(result, "Should return a battery status")

        battery_percent, ac_status = result
        logger.info(f"Battery: {battery_percent}%, AC: {ac_status}")

        self.assertIsInstance(battery_percent, int)
        self.assertGreaterEqual(battery_percent, 0)
        self.assertLessEqual(battery_percent, 100)
        self.assertIn(ac_status, ["Connected", "Disconnected", "Unknown"])

    @unittest.skipIf(not check_upower_availability(), "UPower not available")
    def test_initialize_monitoring(self):
        """Test initializing UPower monitoring."""
        # Mock the battery status check to simulate events
        with mock.patch(
            "src.modules.upower.get_battery_status_upower",
            return_value=(75, "Connected"),
        ):
            success = initialize_upower_monitoring(self.callback_function, self.state)
            self.assertTrue(success, "Monitoring should initialize successfully")

            # Wait a bit to ensure monitoring is started
            time.sleep(2)


def mock_upower_if_needed():
    """
    Create mock UPower interface for testing when actual UPower is not available.
    """
    # If UPower is not available, create mock objects
    if not check_upower_availability():
        logger.info("UPower not available, setting up mocks for testing")
        # Implement mocking here if needed for testing without UPower
        pass


def manual_test():
    """Run a manual test of the UPower module."""
    if not check_upower_availability():
        logger.warning("UPower is not available on this system")
        logger.warning("Install UPower and required Python packages to test")
        return False

    logger.info("Testing UPower monitoring module...")

    # State dict to track battery status
    state = {"battery_percent": 0, "ac_status": "Unknown"}

    # Define a callback for UPower events
    def on_battery_event(battery_percent, ac_status):
        logger.info(f"Battery event received: {battery_percent}%, AC: {ac_status}")
        state["battery_percent"] = battery_percent
        state["ac_status"] = ac_status

    # Initialize UPower monitoring
    success = initialize_upower_monitoring(on_battery_event, state)
    if not success:
        logger.error("Failed to initialize UPower monitoring")
        return False

    logger.info("UPower monitoring started successfully")
    logger.info("Waiting for power events... (press Ctrl+C to exit)")

    try:
        # Wait for events
        while True:
            logger.info(
                f"Current status: {state['battery_percent']}%, AC: {state['ac_status']}"
            )
            time.sleep(5)
    except KeyboardInterrupt:
        logger.info("Test interrupted")

    return True


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--manual":
        # Run manual test
        manual_test()
    else:
        # Run unit tests
        unittest.main()
