#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring and management tool.

Main entry point for battery monitoring application.
Author: Cyber-Syntax
License: BSD 3-Clause License

Example usage:
    python -m src.main
"""

import atexit
import os
import signal
import sys
import time
from typing import Any, Dict

# Use relative imports when running as part of the package, or absolute imports when running directly
try:
    # Try relative imports first (when run as part of the package)
    from .modules.battery import (
        check_battery_exists,
        check_battery_status,
    )
    from .modules.brightness import adjust_brightness
    from .modules.config import Config, load_config
    from .modules.log import get_logger, setup_logging
    from .modules.notification import (
        notify_status_change,
    )
    from .modules.utils import (
        check_dependencies,
        check_lock,
        create_lock_file,
        get_sleep_duration,
        remove_lock_file,
        start_monitoring,
    )
except ImportError:
    # Fall back to absolute imports when run directly
    import sys
    from pathlib import Path

    # Add the parent directory to the Python path
    script_dir = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(script_dir))

    from batteryguardian.modules.battery import (
        check_battery_exists,
        check_battery_status,
    )
    from batteryguardian.modules.brightness import adjust_brightness
    from batteryguardian.modules.config import Config, load_config
    from batteryguardian.modules.log import get_logger, setup_logging
    from batteryguardian.modules.notification import (
        notify_status_change,
    )
    from batteryguardian.modules.utils import (
        check_dependencies,
        check_lock,
        create_lock_file,
        get_sleep_duration,
        remove_lock_file,
        start_monitoring,
    )

# Initialize logger
logger = get_logger(__name__)

# Global state for monitoring threads
MONITORING_THREADS = []


def cleanup(exit_code: int = 0) -> None:
    """
    Perform cleanup operations before exiting.

    Args:
        exit_code: Exit code to return when exiting.
    """
    logger.info("Battery Guardian shutting down with exit code: %d", exit_code)

    # Try to remove the lock file, but don't fail if it's already gone
    try:
        remove_lock_file()
    except Exception as e:
        logger.warning("Error during cleanup while removing lock file: %s", str(e))

    # No need to explicitly terminate threads as they're daemonic


def check_battery_and_adjust_brightness(
    config: Config, previous_state: Dict[str, Any]
) -> Dict[str, Any]:
    """
    Check battery status and adjust brightness accordingly.

    Args:
        config: Application configuration.
        previous_state: Previous battery state.

    Returns:
        Updated state with current battery information.
    """
    # Get current battery percentage and AC status
    battery_percent, ac_status = check_battery_status()

    # Update state
    current_state = {
        "battery_percent": battery_percent,
        "ac_status": ac_status,
        "previous_battery_percent": previous_state.get("battery_percent", 0),
        "previous_ac_status": previous_state.get("ac_status", "Unknown"),
    }

    # Check for changes requiring notifications
    notify_status_change(
        current_state["battery_percent"],
        current_state["previous_battery_percent"],
        current_state["ac_status"],
        current_state["previous_ac_status"],
        config,
    )

    # Adjust screen brightness based on battery status
    if config.get("brightness_control_enabled", True):
        adjust_brightness(battery_percent, ac_status, config)

    return current_state


def main() -> None:
    """
    Main entry point for Battery Guardian application.

    Sets up the environment, monitors battery status, and adjusts
    system brightness based on power conditions.
    """
    # Register cleanup at exit
    atexit.register(cleanup)

    # Set up signal handling for graceful exit
    def signal_handler(sig, _):
        logger.info("Received signal %d, shutting down gracefully", sig)
        cleanup()
        # Don't call sys.exit here, allow the main thread to exit normally
        # which gives threads a chance to exit cleanly
        os._exit(0)  # Force exit if normal exit gets stuck

    # Set up signal handlers for graceful termination
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal_handler)

    # Set up logging
    setup_logging()
    logger.info("Battery Guardian started")

    # Handle keyboard interrupts and other errors gracefully
    try:
        _main_impl()
    except KeyboardInterrupt:
        logger.info("Received keyboard interrupt, shutting down gracefully.")
        sys.exit(0)
    except (KeyboardInterrupt, SystemExit):
        # Re-raise these specific exceptions to allow clean exit
        raise
    except Exception as e:
        logger.error("Unexpected error: %s", str(e), exc_info=True)
        sys.exit(1)


def _main_impl() -> None:
    """
    Main implementation function, separated to allow exception handling.
    """

    # Check dependencies
    if not check_dependencies():
        logger.error("Missing required dependencies. Exiting.")
        sys.exit(1)

    # Check lock file and immediately create it if it doesn't exist
    # This prevents race conditions during startup
    if not check_lock():
        logger.error(
            "Another instance is already running or lock file exists. Exiting."
        )
        sys.exit(1)

    # Create lock file - now we're sure we're good to go
    if not create_lock_file():
        logger.error("Failed to create lock file. Exiting to avoid data corruption.")
        sys.exit(1)

    # Check if a battery is present
    if not check_battery_exists():
        logger.error("No battery detected. Exiting.")
        sys.exit(0)

    # Load configuration
    config = load_config()

    # Initialize state
    state = {
        "battery_percent": 0,
        "ac_status": "Unknown",
        "previous_battery_percent": 0,
        "previous_ac_status": "Unknown",
        "has_changed": 1,  # Start with 1 to force initial reset of back-off
    }

    # Start event-based monitoring
    logger.info("Starting event-based battery monitoring...")
    monitoring_started = start_monitoring(config, state)

    # Initialize monitoring variables (needed regardless of monitoring success)
    event_monitoring_failed = False
    monitoring_check_counter = 0

    # Always enter the polling loop, but with different intervals based on monitoring status
    if not monitoring_started:
        logger.warning("Event-based monitoring could not be initialized.")
        logger.warning("This means higher power consumption due to frequent wake-ups.")
        logger.info("Falling back to polling loop with adaptive back-off strategy.")
        logger.info("To enable efficient event-based monitoring, run:")
        logger.info("  python install_dependencies.py events")
        logger.info("or install dependencies manually as indicated in the logs above.")

    # Main loop - always run this regardless of whether event monitoring was started
    while True:
        # Check if event monitoring has started since we began
        try:
            from .modules.utils import check_monitoring_threads
        except ImportError:
            from batteryguardian.modules.utils import check_monitoring_threads

        if monitoring_started and monitoring_check_counter % 10 == 0:
            # Check every 10 iterations if our event threads are still alive
            if not check_monitoring_threads():
                if not event_monitoring_failed:
                    logger.warning("Event-based monitoring has stopped working")
                    logger.warning("Falling back to polling loop")
                    event_monitoring_failed = True
            elif event_monitoring_failed:
                # Monitoring threads have recovered
                logger.info("Event-based monitoring has recovered")
                event_monitoring_failed = False

        monitoring_check_counter += 1

        # Update state with current battery info
        state = check_battery_and_adjust_brightness(config, state)

        # Detect if status has changed
        has_changed = 0
        if (
            state["previous_battery_percent"] != state["battery_percent"]
            or state["previous_ac_status"] != state["ac_status"]
        ):
            has_changed = 1

        state["has_changed"] = has_changed

        # Get sleep duration based on status and change detection
        sleep_duration = get_sleep_duration(
            state["battery_percent"], state["ac_status"], has_changed, config
        )

        # Validate sleep duration
        if not isinstance(sleep_duration, int) or sleep_duration < 10:
            logger.warning(
                "Invalid sleep duration: '%s'. Using safe default of 30 seconds.",
                str(sleep_duration),
            )
            sleep_duration = 30

        # If event monitoring is working, use longer sleep time for the polling loop
        if monitoring_started and not event_monitoring_failed:
            sleep_duration = max(
                sleep_duration, 60
            )  # At least 60 seconds when event monitoring is active

        # Update previous values for next comparison
        state["previous_battery_percent"] = state["battery_percent"]
        state["previous_ac_status"] = state["ac_status"]

        # Sleep before checking again
        logger.info("Sleeping for %ds (adaptive back-off)", sleep_duration)
        time.sleep(sleep_duration)


# Add a block to run this module directly
if __name__ == "__main__":
    main()
