#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Battery monitoring integration test.

Tests the fallback chain of monitoring methods.
"""

import logging
import sys
import time

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# Import path setup for testing
sys.path.append("/home/developer/Documents/repository/BatteryGuardian")

try:
    from batteryguardian.modules import battery, utils
except ImportError as e:
    logger.error(f"Failed to import modules: {e}")
    sys.exit(1)


def main():
    """Run the monitoring test."""
    logger.info("Testing battery monitoring")

    # Create a state dict for testing
    state = {
        "battery_percent": 0,
        "ac_status": "Unknown",
        "previous_battery_percent": 0,
        "previous_ac_status": "Unknown",
    }

    # Create a minimal config dict
    config = {
        "brightness_control_enabled": False,  # Disable brightness control for testing
        "notification_enabled": False,  # Disable notifications for testing
    }

    # First check if a battery exists
    if not battery.check_battery_exists():
        logger.error("No battery found, cannot test monitoring")
        sys.exit(1)

    # Get initial battery status
    battery_percent, ac_status = battery.check_battery_status()
    logger.info(f"Initial battery status: {battery_percent}%, AC: {ac_status}")

    # Try to start monitoring
    monitoring_started = utils.start_monitoring(config, state)

    if monitoring_started:
        logger.info("Successfully started battery monitoring")
        logger.info(
            "Monitoring method used: "
            + (
                "UPower"
                if battery.UPOWER_AVAILABLE
                else "ACPID"
                if utils.check_command_exists("acpi_listen")
                else "pyudev"
            )
        )

        # Set initial state
        state["battery_percent"] = battery_percent
        state["ac_status"] = ac_status

        # Wait a bit to let monitoring settle
        logger.info("Waiting for events (10 seconds)...")

        # Monitor for 10 seconds
        end_time = time.time() + 10
        while time.time() < end_time:
            # Every 2 seconds, check if the state has been updated
            current_battery, current_ac = battery.check_battery_status()
            logger.info(f"Raw battery status: {current_battery}%, AC: {current_ac}")
            logger.info(
                f"State dict values: {state['battery_percent']}%, AC: {state['ac_status']}"
            )

            # Manually trigger a check (simulating an event)
            if battery.UPOWER_AVAILABLE and time.time() - end_time + 10 > 5:
                logger.info("Triggering a manual battery check...")
                from batteryguardian.modules.upower import get_battery_status_upower

                new_status = get_battery_status_upower()
                if new_status:
                    state["battery_percent"], state["ac_status"] = new_status
                    logger.info(
                        f"Manually updated state: {state['battery_percent']}%, AC: {state['ac_status']}"
                    )

            time.sleep(2)

        # Check if monitoring threads are still active
        if utils.check_monitoring_threads():
            logger.info("Monitoring threads are still active")
        else:
            logger.warning("Monitoring threads have stopped")
    else:
        logger.error("Failed to start monitoring")

    logger.info("Test completed")


if __name__ == "__main__":
    main()
