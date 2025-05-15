#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Fast Power Status Monitor.

This module provides optimized monitoring for power status changes with minimal latency.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import threading
import time
from typing import Any, Callable, Dict, Optional

from .log import get_logger

# Initialize logger
logger = get_logger(__name__)

# Constants
DEVICE_TYPE_AC_ADAPTER = 1
DEVICE_TYPE_BATTERY = 2
AC_PATH_MONITOR_INTERVAL = 0.1  # Check AC status every 100ms in direct polling mode


def setup_fast_ac_monitoring(
    callback: Callable[[int, str], None], state: Dict[str, Any]
) -> bool:
    """
    Set up an ultra-responsive AC adapter status monitor.

    This function attempts to create a dedicated monitor for the AC adapter
    that responds immediately to power changes.

    Args:
        callback: Function to call when power status changes
        state: Shared state dictionary

    Returns:
        True if monitoring was successfully set up, False otherwise
    """
    # First try the most efficient sysfs-based monitoring
    try:
        # Try the direct sysfs polling method first (lowest CPU usage)
        if setup_direct_ac_polling(callback, state):
            logger.info("Successfully set up efficient sysfs-based AC monitoring")
            return True
    except Exception as e:
        logger.debug("Sysfs monitoring setup failed: %s", str(e))
        # Continue to try DBus method

    # Fall back to DBus monitoring if sysfs method failed
    try:
        # Import DBus-related dependencies
        from dbus.mainloop.glib import DBusGMainLoop

        DBusGMainLoop(set_as_default=True)
        import dbus
        import gi

        gi.require_version("GLib", "2.0")
        from gi.repository import GLib

        # Find the AC adapter path
        bus = dbus.SystemBus()
        upower_proxy = bus.get_object(
            "org.freedesktop.UPower", "/org/freedesktop/UPower"
        )
        upower_interface = dbus.Interface(upower_proxy, "org.freedesktop.UPower")
        device_paths = upower_interface.EnumerateDevices()

        ac_adapter_path = None
        for path in device_paths:
            device = bus.get_object("org.freedesktop.UPower", path)
            device_interface = dbus.Interface(device, "org.freedesktop.DBus.Properties")
            device_type = device_interface.Get("org.freedesktop.UPower.Device", "Type")

            if device_type == DEVICE_TYPE_AC_ADAPTER:
                ac_adapter_path = path
                logger.debug("Found AC adapter at path: %s", str(ac_adapter_path))
                break

        if not ac_adapter_path:
            logger.warning("No AC adapter found via UPower")
            return False

        # Create a dedicated main loop for AC adapter events
        def run_ac_monitor():
            try:
                main_loop = GLib.MainLoop()

                # Function to get complete status
                def get_complete_status():
                    try:
                        from .battery import check_battery_status

                        battery_percent, ac_status = check_battery_status()
                        callback(battery_percent, ac_status)
                        logger.debug(
                            "Background status update complete: battery=%d%%, AC=%s",
                            battery_percent,
                            ac_status,
                        )
                    except Exception as e:
                        logger.error("Error in background status update: %s", str(e))

                # Optimized handler just for AC adapter
                def ac_signal_handler(*_args, **_kwargs):
                    try:
                        # Start timing
                        start_time = time.time()

                        # Get AC status directly from device for fastest response
                        device = bus.get_object(
                            "org.freedesktop.UPower", ac_adapter_path
                        )
                        device_interface = dbus.Interface(
                            device, "org.freedesktop.DBus.Properties"
                        )
                        online = device_interface.Get(
                            "org.freedesktop.UPower.Device", "Online"
                        )
                        ac_status = "Connected" if bool(online) else "Disconnected"

                        # Use cached battery percentage to avoid delays
                        battery_percent = state.get("battery_percent", 50)

                        # Update the UI immediately with the new AC status
                        callback(battery_percent, ac_status)

                        # Log response time
                        elapsed_ms = (time.time() - start_time) * 1000
                        logger.info(
                            "Ultra-fast AC status update: %s (%.2f ms)",
                            ac_status,
                            elapsed_ms,
                        )

                        # Then get complete status in background
                        threading.Thread(
                            target=get_complete_status,
                            daemon=True,
                            name="CompleteStatusUpdate",
                        ).start()
                    except Exception as e:
                        logger.error("Error in AC signal handler: %s", str(e))

                # Set up signal receiver specifically for the AC adapter
                bus.add_signal_receiver(
                    ac_signal_handler,
                    dbus_interface="org.freedesktop.UPower.Device",
                    signal_name="Changed",
                    path=ac_adapter_path,
                )

                logger.info("Started ultra-responsive AC adapter monitoring via DBus")
                main_loop.run()

            except Exception as e:
                logger.error("Error in AC adapter monitoring thread: %s", str(e))

        # Start the monitoring thread
        monitor_thread = threading.Thread(
            target=run_ac_monitor, daemon=True, name="FastACMonitor"
        )
        monitor_thread.start()

        return True

    except Exception as e:
        logger.error("Failed to set up any AC monitoring: %s", str(e))
        return False


def setup_direct_ac_polling(
    callback: Callable[[int, str], None],
    state: Dict[str, Any],
    ac_path: Optional[str] = None,
) -> bool:
    """
    Set up direct polling of AC adapter status at a high frequency using sysfs.

    This acts as a fallback mechanism when D-Bus signals might be delayed.
    The sysfs polling method is extremely efficient and minimizes CPU usage.

    Args:
        callback: Function to call when power status changes
        state: Shared state dictionary
        ac_path: Path to the AC adapter (optional, not used in sysfs approach)

    Returns:
        True if polling was set up, False otherwise
    """
    try:
        import glob
        from pathlib import Path

        # Find AC adapter paths in sysfs
        ac_adapter_paths = glob.glob("/sys/class/power_supply/AC*") + glob.glob(
            "/sys/class/power_supply/ACAD*"
        )

        # Exit if no AC adapter found
        if not ac_adapter_paths:
            logger.warning("No AC adapter found in sysfs for direct polling")
            return False

        # Use the first adapter found (most systems only have one)
        ac_adapter_sysfs = ac_adapter_paths[0]
        ac_online_path = Path(ac_adapter_sysfs, "online")

        # Check if the online file exists and is readable
        if not ac_online_path.is_file():
            logger.warning(
                f"AC adapter online status file not found at {ac_online_path}"
            )
            return False

        logger.info(f"Using sysfs AC adapter at {ac_adapter_sysfs}")

        # Store the last known state to detect changes
        last_status = {"ac_online": None, "last_change": 0}

        def poll_ac_status():
            try:
                while True:
                    try:
                        # Read AC status directly from sysfs (ultra-fast, minimal CPU usage)
                        with open(ac_online_path, "r") as f:
                            online_status = f.read().strip()
                            online = online_status == "1"

                        # If status changed or this is the first check
                        if (
                            last_status["ac_online"] is None
                            or last_status["ac_online"] != online
                        ):
                            start_time = time.time()
                            ac_status = "Connected" if online else "Disconnected"

                            # Update last known status
                            last_status["ac_online"] = online
                            last_status["last_change"] = start_time

                            # Start a background thread to get accurate battery percentage
                            # and show notification immediately
                            threading.Thread(
                                target=lambda: get_complete_status_and_notify(
                                    callback, ac_status
                                ),
                                daemon=True,
                                name="ACStatusChangeNotifier",
                            ).start()

                            # Log the fast detection
                            logger.info(
                                "Sysfs polling detected AC status change: %s",
                                ac_status,
                            )

                            # Get complete status in background
                            threading.Thread(
                                target=lambda: get_complete_status(callback),
                                daemon=True,
                                name="SysfsPollCompleteUpdate",
                            ).start()
                    except (IOError, OSError, FileNotFoundError) as e:
                        logger.debug("Error reading AC status from sysfs: %s", str(e))
                        # If we can't read the file, wait a bit longer before retrying
                        time.sleep(1)
                        continue
                    except Exception as e:
                        logger.debug("Unexpected error polling AC status: %s", str(e))

                    # Sleep briefly - short enough for responsive updates but not so short to waste CPU
                    time.sleep(AC_PATH_MONITOR_INTERVAL)
            except Exception as e:
                logger.error("AC sysfs polling thread error: %s", str(e))

        # Function to get complete power status
        def get_complete_status(cb):
            try:
                from .battery import check_battery_status

                battery_percent, ac_status = check_battery_status()
                cb(battery_percent, ac_status)
            except Exception as e:
                logger.error("Error in background status update: %s", str(e))

        # Function to get accurate battery status and immediately notify about AC changes
        def get_complete_status_and_notify(cb, current_ac_status):
            try:
                from .battery import get_battery_percentage

                # Get fresh battery percentage for accurate notifications
                battery_percent = get_battery_percentage()

                # Call callback with accurate battery percentage and current AC status
                cb(battery_percent, current_ac_status)

                logger.info(
                    f"AC status change notification with accurate battery: {battery_percent}%"
                )
            except Exception as e:
                logger.error(f"Error in AC status change notification: {str(e)}")
                # Fall back to using the callback function with default values
                try:
                    battery_percent = state.get("battery_percent", 50)
                    cb(battery_percent, current_ac_status)
                except Exception as nested_e:
                    logger.error(
                        f"Failed to send fallback notification: {str(nested_e)}"
                    )

        # Start the polling thread
        polling_thread = threading.Thread(
            target=poll_ac_status, daemon=True, name="SysfsACStatusPoller"
        )
        polling_thread.start()

        logger.info("Started efficient sysfs-based AC adapter polling")
        return True

    except Exception as e:
        logger.error("Failed to set up sysfs AC polling: %s", str(e))
        return False
