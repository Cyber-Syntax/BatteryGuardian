#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - ACPID monitoring module.

This module handles ACPID monitoring as a fallback for UPower.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import subprocess
import threading
import time
from typing import Any, Callable, Dict

from .log import get_logger
from .utils import check_command_exists

# Initialize logger
logger = get_logger(__name__)


def check_acpid_availability() -> bool:
    """
    Check if acpi_listen command is available on the system.

    Returns:
        True if acpi_listen is available, False otherwise
    """
    return check_command_exists("acpi_listen")


def initialize_acpid_monitoring(
    callback: Callable[[int, str], None], state: Dict[str, Any]
) -> bool:
    """
    Initialize ACPI event monitoring using acpi_listen.

    Args:
        callback: Function to call when battery status changes with signature (battery_percent, ac_status)
        state: Shared state dictionary for tracking battery status

    Returns:
        True if monitoring was successfully started, False otherwise
    """
    if not check_acpid_availability():
        logger.warning("acpi_listen command not found, cannot use ACPI monitoring")
        logger.info("Install acpid package on your system to enable ACPI monitoring")
        return False

    try:
        logger.info("Attempting to use acpi_listen for event-based monitoring")

        # Create a function to monitor acpi events
        def monitor_acpi_events():
            try:
                # Start acpi_listen process
                process = subprocess.Popen(
                    ["acpi_listen"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    bufsize=1,
                )

                logger.info("Started acpi_listen monitoring")

                # Process events from acpi_listen
                try:
                    for line in iter(process.stdout.readline, ""):
                        # Check if this is a battery or AC event
                        if (
                            "battery" in line.lower()
                            or "ac" in line.lower()
                            or "power" in line.lower()
                        ):
                            try:
                                # Process battery event
                                from .battery import check_battery_status

                                battery_percent, ac_status = check_battery_status()

                                # Call the callback with new status
                                callback(battery_percent, ac_status)

                                logger.debug(
                                    "Processed ACPI event: battery=%d%%, AC=%s",
                                    battery_percent,
                                    ac_status,
                                )
                            except Exception as e:
                                logger.error("Error processing ACPI event: %s", str(e))
                except KeyboardInterrupt:
                    logger.info("ACPI monitoring interrupted")
                finally:
                    # Clean up the process
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()

                # If we get here normally, acpi_listen has terminated
                logger.warning("acpi_listen process terminated unexpectedly")

            except Exception as e:
                logger.error("Error in ACPI monitoring thread: %s", str(e))

        # Start the monitoring in a separate thread
        thread = threading.Thread(
            target=monitor_acpi_events, daemon=True, name="ACPIMonitor"
        )
        thread.start()

        # Give it a moment to initialize and check if it's still running
        time.sleep(1)
        if thread.is_alive():
            logger.info("Successfully started ACPI battery monitoring")
            return True
        else:
            logger.warning("ACPI monitoring thread failed to start")

    except Exception as e:
        logger.warning("Failed to set up acpi_listen monitoring: %s", str(e))

    return False
