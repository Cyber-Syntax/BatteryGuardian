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

                logger.info("Started ultra-responsive AC adapter monitoring")
                main_loop.run()

            except Exception as e:
                logger.error("Error in AC adapter monitoring thread: %s", str(e))

        # Start the monitoring thread
        monitor_thread = threading.Thread(
            target=run_ac_monitor, daemon=True, name="FastACMonitor"
        )
        monitor_thread.start()

        # Also set up direct polling as a fallback if needed
        setup_direct_ac_polling(callback, state, ac_adapter_path)

        return True

    except Exception as e:
        logger.error("Failed to set up fast AC monitoring: %s", str(e))
        return False


def setup_direct_ac_polling(
    callback: Callable[[int, str], None],
    state: Dict[str, Any],
    ac_path: Optional[str] = None,
) -> bool:
    """
    Set up direct polling of AC adapter status at a high frequency.

    This acts as a fallback mechanism when D-Bus signals might be delayed.

    Args:
        callback: Function to call when power status changes
        state: Shared state dictionary
        ac_path: Path to the AC adapter (optional)

    Returns:
        True if polling was set up, False otherwise
    """
    try:
        from dbus.mainloop.glib import DBusGMainLoop

        DBusGMainLoop(set_as_default=True)
        import dbus

        # If no AC path provided, try to find it
        if not ac_path:
            bus = dbus.SystemBus()
            upower_proxy = bus.get_object(
                "org.freedesktop.UPower", "/org/freedesktop/UPower"
            )
            upower_interface = dbus.Interface(upower_proxy, "org.freedesktop.UPower")
            device_paths = upower_interface.EnumerateDevices()

            for path in device_paths:
                device = bus.get_object("org.freedesktop.UPower", path)
                device_interface = dbus.Interface(
                    device, "org.freedesktop.DBus.Properties"
                )
                device_type = device_interface.Get(
                    "org.freedesktop.UPower.Device", "Type"
                )

                if device_type == DEVICE_TYPE_AC_ADAPTER:
                    ac_path = path
                    break

        if not ac_path:
            logger.warning("No AC adapter found for direct polling")
            return False

        # Store the last known state to detect changes
        last_status = {"ac_online": None, "last_change": 0}

        def poll_ac_status():
            bus = None
            try:
                bus = dbus.SystemBus()

                while True:
                    try:
                        # Check AC status directly (very fast)
                        device = bus.get_object("org.freedesktop.UPower", ac_path)
                        device_interface = dbus.Interface(
                            device, "org.freedesktop.DBus.Properties"
                        )
                        online = bool(
                            device_interface.Get(
                                "org.freedesktop.UPower.Device", "Online"
                            )
                        )

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

                            # Use cached battery percentage for immediate response
                            battery_percent = state.get("battery_percent", 50)

                            # Call the callback with the updated status
                            callback(battery_percent, ac_status)

                            # Log the fast detection
                            logger.info(
                                "Direct polling detected AC status change: %s",
                                ac_status,
                            )

                            # Get complete status in background
                            threading.Thread(
                                target=lambda: get_complete_status(callback),
                                daemon=True,
                                name="PollCompleteUpdate",
                            ).start()
                    except Exception as e:
                        logger.debug("Error polling AC status: %s", str(e))

                    # Sleep briefly - short enough for responsive updates but not so short to waste CPU
                    time.sleep(AC_PATH_MONITOR_INTERVAL)
            except Exception as e:
                logger.error("AC polling thread error: %s", str(e))

        # Function to get complete power status
        def get_complete_status(cb):
            try:
                from .battery import check_battery_status

                battery_percent, ac_status = check_battery_status()
                cb(battery_percent, ac_status)
            except Exception as e:
                logger.error("Error in background status update: %s", str(e))

        # Start the polling thread
        polling_thread = threading.Thread(
            target=poll_ac_status, daemon=True, name="ACStatusPoller"
        )
        polling_thread.start()

        logger.info("Started direct AC adapter polling")
        return True

    except Exception as e:
        logger.error("Failed to set up direct AC polling: %s", str(e))
        return False
