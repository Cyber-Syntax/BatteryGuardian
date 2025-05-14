#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
UPower monitoring test script.

This is a standalone script to test UPower monitoring.
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


def try_upower():
    """Attempt to import and connect to UPower via D-Bus."""
    try:
        import dbus  # From python-dbus binding
    except ImportError:
        logger.warning("dbus-python not installed. Run: pip install dbus-python")
        return None

    try:
        bus = dbus.SystemBus()
        upower = bus.get_object("org.freedesktop.UPower", "/org/freedesktop/UPower")
        iface = dbus.Interface(upower, "org.freedesktop.UPower")
        return iface
    except dbus.DBusException as e:
        logger.warning(f"UPower daemon not available: {e}")
        return None


def try_acpid_socket():
    """Attempt to connect to the acpid UNIX socket."""
    import socket

    sock_path = "/var/run/acpid.socket"
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(sock_path)
        return client
    except FileNotFoundError:
        logger.warning(f"acpid socket not found at {sock_path}. Install/enable acpid.")
    except PermissionError:
        logger.warning(
            f"No permission to access {sock_path}. "
            "Check socket permissions or run as root."
        )
    return None


def fallback_polling(interval=60):
    """Return a simple polling function that sleeps for `interval` seconds."""

    def poll():
        # Replace this stub with your real battery check:
        logger.info("Polling battery status...")
        # e.g., shell out to `upower -i /classor read /class/…
        time.sleep(interval)

    return poll


def get_battery_status_upower():
    """Get battery status using UPower."""
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
                logger.info(f"Found AC adapter: {ac_status}")

            # Check for battery (type 2)
            elif device_type == 2 and not battery_found:  # Battery
                battery_found = True
                percentage = device_interface.Get(
                    "org.freedesktop.UPower.Device", "Percentage"
                )
                battery_percent = int(percentage)
                logger.info(f"Found battery at {battery_percent}%")

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
                    logger.info(f"Battery state: {state}, inferred AC: {ac_status}")

        if not battery_found:
            logger.warning("No battery found via UPower")
            return None

        return battery_percent, ac_status

    except Exception as e:
        logger.exception(f"Error accessing UPower: {e}")
        return None


def main():
    # 1) First test battery status reading
    logger.info("Testing battery status reading...")
    status = get_battery_status_upower()
    if status:
        battery_percent, ac_status = status
        logger.info(f"Battery: {battery_percent}%, AC: {ac_status}")
    else:
        logger.warning("Failed to read battery status from UPower")

    # 2) Try UPower event monitoring
    upower_iface = try_upower()
    if upower_iface:
        logger.info("Using UPower for events.")

        def on_changed():
            logger.info("UPower event received!")
            status = get_battery_status_upower()
            if status:
                battery_percent, ac_status = status
                logger.info(f"Battery: {battery_percent}%, AC: {ac_status}")

        try:
            # Set up event monitoring
            import dbus
            from dbus.mainloop.glib import DBusGMainLoop

            # Initialize DBus with Glib mainloop
            DBusGMainLoop(set_as_default=True)

            # Get system bus
            bus = dbus.SystemBus()

            # Register signal handlers
            bus.add_signal_receiver(
                on_changed,
                dbus_interface="org.freedesktop.UPower.Device",
                signal_name="Changed",
            )

            bus.add_signal_receiver(
                on_changed,
                dbus_interface="org.freedesktop.UPower",
                signal_name="DeviceChanged",
            )

            logger.info("Registered UPower signal handlers")

            # Start GLib main loop
            logger.info("Starting main loop. Waiting for power events...")
            import gi

            gi.require_version("GLib", "2.0")
            from gi.repository import GLib

            loop = GLib.MainLoop()
            loop.run()

        except ImportError as e:
            logger.warning(f"Failed to set up event monitoring: {e}")
            logger.warning("Falling back to polling")
            poll = fallback_polling(interval=10)
            while True:
                poll()
        return

    # 3) Try acpid socket
    sock = try_acpid_socket()
    if sock:
        logger.info("Listening on acpid socket for ACPI events.")
        while True:
            data = sock.recv(1024)
            if data:
                logger.info(f"ACPI Event: {data.decode().strip()}")
        return

    # 4) Fallback to polling
    logger.info("No event sources available; entering polling mode.")
    poll = fallback_polling(interval=10)
    while True:
        poll()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logger.info("Monitoring stopped by user.")
    except Exception as e:
        logger.exception(f"Unexpected error: {e}")
        sys.exit(1)
