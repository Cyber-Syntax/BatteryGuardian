#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - UPower monitoring module.

This module handles UPower D-Bus monitoring in a robust way.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import threading
import time
from typing import Any, Callable, Dict, Optional

from .log import get_logger

# Initialize logger
logger = get_logger(__name__)


def initialize_upower_monitoring(
    callback: Callable[[int, str], None], state: Dict[str, Any]
) -> bool:
    """
    Initialize UPower monitoring using DBus.

    This function sets up UPower monitoring in a separate thread that handles
    the GLib main loop properly.

    Args:
        callback: Function to call when battery status changes with signature (battery_percent, ac_status)
        state: Shared state dictionary for tracking battery status

    Returns:
        True if monitoring was successfully started, False otherwise
    """
    # Try to import required modules
    try:
        import dbus
        import gi
        from dbus.mainloop.glib import DBusGMainLoop

        gi.require_version("GLib", "2.0")
        from gi.repository import GLib
    except ImportError as e:
        logger.warning(f"Failed to import UPower dependencies: {e}")
        logger.info(
            "To enable UPower monitoring, install: pip install dbus-python PyGObject"
        )
        return False

    # Create a thread to run the GLib main loop
    def run_upower_monitor():
        try:
            # Set up DBus with GLib main loop
            logger.info("Initializing D-Bus main loop for UPower monitoring")
            DBusGMainLoop(set_as_default=True)

            # Create the main loop
            main_loop = GLib.MainLoop()

            # Connect to system bus
            bus = dbus.SystemBus()

            # Create signal handler
            def power_signal_handler(*_args, **_kwargs):
                try:
                    # Get current battery status
                    from .battery import check_battery_status

                    battery_percent, ac_status = check_battery_status()

                    # Call the callback with new status
                    callback(battery_percent, ac_status)

                    logger.debug(
                        f"Processed UPower event: battery={battery_percent}%, AC={ac_status}"
                    )
                except Exception as e:
                    logger.error(f"Error in UPower signal handler: {e}")

            # Set up signal receivers for UPower
            try:
                # Listen for UPower Device signals
                bus.add_signal_receiver(
                    power_signal_handler,
                    dbus_interface="org.freedesktop.UPower.Device",
                    signal_name="Changed",
                )

                # Listen for general UPower changes
                bus.add_signal_receiver(
                    power_signal_handler,
                    dbus_interface="org.freedesktop.UPower",
                    signal_name="DeviceChanged",
                )

                logger.info("Successfully connected to UPower D-Bus signals")

                # Run the main loop
                logger.info("Starting UPower monitoring main loop")
                main_loop.run()
            except Exception as e:
                logger.error(f"Failed to set up UPower monitoring: {e}")
                if main_loop and main_loop.is_running():
                    main_loop.quit()
                return

        except Exception as e:
            logger.error(f"Error in UPower monitoring thread: {e}")

    # Start the monitoring thread
    monitor_thread = threading.Thread(
        target=run_upower_monitor, daemon=True, name="UPowerMonitor"
    )

    try:
        monitor_thread.start()

        # Give it a moment to initialize
        time.sleep(1)

        if monitor_thread.is_alive():
            logger.info("Successfully started UPower battery monitoring")
            return True
        else:
            logger.warning("UPower monitoring thread failed to start")
            return False
    except Exception as e:
        logger.error(f"Failed to start UPower monitoring thread: {e}")
        return False


def check_upower_availability() -> bool:
    """
    Check if UPower service is available via D-Bus.

    Returns:
        True if UPower is available, False otherwise
    """
    try:
        import dbus

        bus = dbus.SystemBus()
        bus.get_object("org.freedesktop.UPower", "/org/freedesktop/UPower")
        return True
    except (ImportError, Exception) as e:
        logger.debug(f"UPower service not available: {e}")
        return False


def get_battery_status_upower() -> Optional[tuple[int, str]]:
    """
    Get battery status using UPower.

    Returns:
        Tuple of (battery_percentage, ac_status) or None if failed
    """
    try:
        import dbus

        bus = dbus.SystemBus()
        upower_proxy = bus.get_object(
            "org.freedesktop.UPower", "/org/freedesktop/UPower"
        )

        # Get all devices
        upower_interface = dbus.Interface(upower_proxy, "org.freedesktop.UPower")
        device_paths = upower_interface.EnumerateDevices()

        # Find the first battery
        battery_percent = 0
        ac_status = "Unknown"
        ac_connected = False
        battery_found = False

        for path in device_paths:
            device = bus.get_object("org.freedesktop.UPower", path)
            device_interface = dbus.Interface(device, "org.freedesktop.DBus.Properties")
            device_type = device_interface.Get("org.freedesktop.UPower.Device", "Type")

            # Check for AC adapter (type 1)
            if device_type == 1:  # AC adapter
                online = device_interface.Get("org.freedesktop.UPower.Device", "Online")
                ac_connected = bool(online)
                ac_status = "Connected" if ac_connected else "Disconnected"
                logger.debug(f"Found AC adapter: {ac_status}")

            # Check for battery (type 2)
            elif device_type == 2 and not battery_found:  # Battery
                battery_found = True
                percentage = device_interface.Get(
                    "org.freedesktop.UPower.Device", "Percentage"
                )
                battery_percent = int(percentage)
                logger.debug(f"Found battery at {battery_percent}%")

                # If we have no AC status yet, try to infer from battery state
                if ac_status == "Unknown":
                    state = device_interface.Get(
                        "org.freedesktop.UPower.Device", "State"
                    )
                    # State: 1=charging, 2=discharging, 3=empty, 4=fully charged, 5=pending charge, 6=pending discharge
                    if state in (1, 4, 5):
                        ac_status = "Connected"
                    elif state in (2, 3, 6):
                        ac_status = "Disconnected"

        if not battery_found:
            logger.warning("No battery found via UPower")
            return None

        return battery_percent, ac_status

    except Exception as e:
        logger.warning(f"Error accessing UPower: {e}")
        return None
