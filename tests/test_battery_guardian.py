#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian Test Script.

This script tests the battery monitoring functionality.
It helps diagnose issues with UPower, ACPID, and polling methods.
"""

import logging
import sys
import time
from typing import Any, Dict

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# Add module path
sys.path.append("/home/developer/Documents/repository/BatteryGuardian")

# Import our modules
try:
    from batteryguardian.modules import acpid, battery, upower, utils
except ImportError as e:
    logger.error(f"Error importing modules: {e}")
    sys.exit(1)


def test_upower():
    """Test UPower functionality."""
    logger.info("Testing UPower functionality...")

    if not upower.check_upower_availability():
        logger.warning("UPower service is not available on this system")
        return False

    # Test getting battery status
    battery_status = upower.get_battery_status_upower()
    if battery_status:
        percent, ac_status = battery_status
        logger.info(f"Battery at {percent}%, AC is {ac_status}")
    else:
        logger.warning("Failed to get battery status from UPower")
        return False

    # Test monitoring
    state = {"battery_percent": 0, "ac_status": "Unknown"}

    def on_battery_event(battery_percent, ac_status):
        logger.info(f"Event received: Battery {battery_percent}%, AC {ac_status}")

    success = upower.initialize_upower_monitoring(on_battery_event, state)
    if success:
        logger.info("UPower monitoring started successfully. Waiting for events...")
        try:
            # Wait for events
            for _ in range(10):
                time.sleep(2)
                logger.info("Monitoring active...")
            return True
        except KeyboardInterrupt:
            logger.info("Test interrupted")
    else:
        logger.warning("Failed to start UPower monitoring")
        return False


def test_acpid():
    """Test ACPID functionality."""
    logger.info("Testing ACPID functionality...")

    if not acpid.check_acpid_availability():
        logger.warning("acpi_listen is not available on this system")
        return False

    # Test monitoring
    state = {"battery_percent": 0, "ac_status": "Unknown"}

    def on_battery_event(battery_percent, ac_status):
        logger.info(f"Event received: Battery {battery_percent}%, AC {ac_status}")

    success = acpid.initialize_acpid_monitoring(on_battery_event, state)
    if success:
        logger.info("ACPID monitoring started successfully. Waiting for events...")
        try:
            # Wait for events
            for _ in range(10):
                time.sleep(2)
                logger.info("Monitoring active...")
            return True
        except KeyboardInterrupt:
            logger.info("Test interrupted")
    else:
        logger.warning("Failed to start ACPID monitoring")
        return False


def test_monitoring():
    """Test the complete monitoring system."""
    logger.info("Testing battery monitoring functionality...")

    # Create config and state
    config = {
        "brightness_control_enabled": False,  # Disable brightness control for test
        "notification_enabled": False,  # Disable notifications for test
        "backoff_initial": 5,
        "backoff_max": 30,
        "backoff_factor": 1.5,
    }

    state: Dict[str, Any] = {
        "battery_percent": 0,
        "ac_status": "Unknown",
    }

    # Start monitoring
    success = utils.start_monitoring(config, state)

    if success:
        logger.info("Monitoring started successfully. Monitoring for 30 seconds...")
        try:
            # Monitor for 30 seconds
            for i in range(15):
                time.sleep(2)
                logger.info(
                    f"Current state: {state['battery_percent']}%, AC: {state['ac_status']}"
                )
            return True
        except KeyboardInterrupt:
            logger.info("Test interrupted")
    else:
        logger.warning("Failed to start monitoring")

    return False


if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "upower":
            test_upower()
        elif sys.argv[1] == "acpid":
            test_acpid()
        else:
            print(f"Unknown test: {sys.argv[1]}")
            print("Available tests: upower, acpid, all")
    else:
        # Run all tests
        logger.info("Running full monitoring test...")
        test_monitoring()
