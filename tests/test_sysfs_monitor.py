#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Test script for sysfs-based AC adapter monitoring.

This module tests the sysfs-based monitoring approach for AC adapter status changes.
Author: Cyber-Syntax
License: BSD 3-Clause License
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

try:
    from batteryguardian.modules.battery import check_battery_status, get_ac_status
    from batteryguardian.modules.fast_power_monitor import setup_direct_ac_polling
except ImportError as e:
    logger.error(f"Error importing modules: {e}")
    sys.exit(1)


def test_sysfs_monitoring() -> bool:
    """Test the sysfs-based AC adapter monitoring."""
    logger.info("Testing sysfs-based AC adapter monitoring...")

    # Create a simple state dictionary
    state: Dict[str, Any] = {"battery_percent": 0, "ac_status": "Unknown"}

    # Define a callback function for monitoring
    def on_power_event(battery_percent: int, ac_status: str) -> None:
        logger.info(f"Power event detected: Battery {battery_percent}%, AC {ac_status}")

    # Check current AC status using direct read
    current_ac_status = get_ac_status()
    logger.info(f"Current AC status (direct read): {current_ac_status}")

    # Start the sysfs-based monitoring
    success = setup_direct_ac_polling(on_power_event, state)

    if not success:
        logger.error("Failed to set up sysfs-based AC monitoring")
        return False

    logger.info("Sysfs-based monitoring started successfully")
    logger.info("Please connect/disconnect your AC adapter to trigger events...")
    logger.info("Press Ctrl+C to stop the test")

    try:
        # Keep the test running to observe AC adapter events
        for i in range(30):  # Run for about 30 seconds
            time.sleep(1)
            if i % 5 == 0:
                current_status = get_ac_status()
                logger.info(f"Current AC status: {current_status}")
    except KeyboardInterrupt:
        logger.info("Test stopped by user")

    return True


if __name__ == "__main__":
    try:
        test_sysfs_monitoring()
    except Exception as e:
        logger.exception(f"Test failed with error: {e}")
