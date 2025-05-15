#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ACPID module test script.

Tests the ACPID monitoring module implementation.
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

# Try to import the ACPID module
try:
    from batteryguardian.modules.acpid import (
        check_acpid_availability,
        initialize_acpid_monitoring,
    )
    from batteryguardian.modules.utils import check_command_exists
except ImportError as e:
    logger.error(f"Failed to import ACPID module: {e}")
    logger.error("Make sure you're running this from the project root directory")
    sys.exit(1)


class TestACPIDModule(unittest.TestCase):
    """Test cases for the ACPID monitoring module."""

    def setUp(self):
        """Set up test fixtures."""
        self.state = {"battery_percent": 0, "ac_status": "Unknown"}
        self.event_received = threading.Event()
        self.battery_percent = 0
        self.ac_status = "Unknown"

    def callback_function(self, battery_percent, ac_status):
        """Callback function for ACPID events."""
        self.battery_percent = battery_percent
        self.ac_status = ac_status
        self.event_received.set()
        logger.info(f"Received event: battery={battery_percent}%, AC={ac_status}")

    def test_acpid_availability(self):
        """Test that we can detect acpi_listen availability."""
        # This test should pass if acpi_listen is available or be skipped if not
        is_available = check_acpid_availability()
        if not is_available:
            self.skipTest("acpi_listen is not available on this system")
        self.assertTrue(is_available)

    @unittest.skipIf(
        not check_command_exists("acpi_listen"), "acpi_listen not available"
    )
    def test_initialize_monitoring(self):
        """Test initializing ACPID monitoring."""
        # Mock the subprocess call to simulate acpi_listen
        with mock.patch(
            "subprocess.Popen",
            return_value=mock.Mock(
                stdout=mock.Mock(readline=lambda: "battery BAT0 00000080 00000001\n"),
                stderr=mock.Mock(),
                terminate=mock.Mock(),
                wait=mock.Mock(),
            ),
        ):
            with mock.patch(
                "src.modules.battery.check_battery_status",
                return_value=(75, "Connected"),
            ):
                success = initialize_acpid_monitoring(
                    self.callback_function, self.state
                )
                self.assertTrue(success, "Monitoring should initialize successfully")

                # Wait a bit to ensure monitoring is started
                time.sleep(2)


def manual_test():
    """Run a manual test of the ACPID module."""
    if not check_acpid_availability():
        logger.warning("acpi_listen is not available on this system")
        logger.warning("Install acpid package to test")
        return False

    logger.info("Testing ACPID monitoring module...")

    # State dict to track battery status
    state = {"battery_percent": 0, "ac_status": "Unknown"}

    # Define a callback for ACPID events
    def on_battery_event(battery_percent, ac_status):
        logger.info(f"Battery event received: {battery_percent}%, AC: {ac_status}")
        state["battery_percent"] = battery_percent
        state["ac_status"] = ac_status

    # Initialize ACPID monitoring
    success = initialize_acpid_monitoring(on_battery_event, state)
    if not success:
        logger.error("Failed to initialize ACPID monitoring")
        return False

    logger.info("ACPID monitoring started successfully")
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
