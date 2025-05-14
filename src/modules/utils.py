#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring and management tool.

Utility functions for general operations.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import atexit
import os
import shutil
import subprocess
import threading
import time
from typing import Any, Dict

from .log import get_app_dirs, get_logger

# Initialize logger
logger = get_logger(__name__)

# Global list to track monitoring threads
MONITORING_THREADS = []


def check_command_exists(cmd: str) -> bool:
    """
    Check if a command exists in the system PATH.

    Args:
        cmd: Command to check

    Returns:
        True if command exists, False otherwise
    """
    return shutil.which(cmd) is not None


def check_dependencies() -> bool:
    """
    Check for required dependencies.

    Returns:
        True if all required dependencies are available, False otherwise
    """
    # Skip all checks in test mode
    if os.environ.get("BG_TEST_MODE") == "true":
        logger.info("Running in test mode, skipping dependency checks")
        return True

    missing_deps = 0

    # Check for notify-send (required)
    if not check_command_exists("notify-send"):
        logger.warning("Missing required dependency: notify-send")
        logger.warning("Please install a notification daemon like dunst or libnotify")
        missing_deps += 1
        # Return failure immediately for notify-send as it's critical
        return False

    # Check for at least one brightness control method
    if not any(
        check_command_exists(cmd) for cmd in ["brightnessctl", "light", "xbacklight"]
    ):
        logger.warning(
            "No brightness control tool found (brightnessctl, light, or xbacklight)"
        )
        logger.warning(
            "Brightness control will fall back to direct sysfs access if available"
        )

    return missing_deps == 0


def create_lock_file() -> bool:
    """
    Create a lock file to prevent multiple instances from running.

    Returns:
        True if lock file was created successfully, False otherwise
    """
    app_dirs = get_app_dirs()
    lock_file = app_dirs["runtime_dir"] / "battery-guardian.lock"

    try:
        with open(lock_file, "w", encoding="utf-8") as f:
            f.write(str(os.getpid()))
        return True
    except (IOError, PermissionError) as e:
        logger.error("Failed to create lock file: %s", str(e))
        return False


def check_lock() -> bool:
    """
    Check if another instance is already running by examining the lock file.

    Returns:
        True if no other instance is running, False otherwise
    """
    app_dirs = get_app_dirs()
    lock_file = app_dirs["runtime_dir"] / "battery-guardian.lock"

    if not lock_file.exists():
        return True

    try:
        # Read the PID from lock file
        with open(lock_file, "r", encoding="utf-8") as f:
            content = f.read().strip()
            try:
                pid = int(content)
            except ValueError:
                logger.warning("Invalid PID in lock file: %s", content)
                lock_file.unlink(missing_ok=True)
                return True

        # Check if the process is still running
        try:
            # Try to send signal 0 to check if process exists
            os.kill(pid, 0)
            
            # Process exists, but let's do a more thorough check to make sure
            # it's actually our application and not some other process with the same PID
            try:
                # Try to get the process name from /proc
                proc_path = f"/proc/{pid}/cmdline"
                if os.path.exists(proc_path):
                    with open(proc_path, "r", encoding="utf-8") as f:
                        cmdline = f.read()
                        # Check if it looks like our application
                        if "battery" not in cmdline.lower() and "guardian" not in cmdline.lower():
                            logger.warning("Found process with PID %d but it appears to be a different application", pid)
                            logger.info("Removing stale lock file")
                            lock_file.unlink(missing_ok=True)
                            return True
                
                logger.warning("Another instance is already running (PID: %d)", pid)
                return False
            except (IOError, PermissionError):
                # Can't read process info, assume it's our process to be safe
                logger.warning("Another instance is already running (PID: %d)", pid)
                return False
                
        except OSError:
            # Process not found, remove stale lock
            logger.info("Detected stale lock file, removing it")
            lock_file.unlink(missing_ok=True)
            return True
            
    except (IOError, ValueError) as e:
        logger.warning("Invalid lock file found: %s", str(e))
        # Invalid lock file, safe to proceed
        try:
            lock_file.unlink(missing_ok=True)
        except Exception as e:
            logger.warning("Error removing invalid lock file: %s", str(e))
        return True
    except Exception as e:
        logger.error("Unexpected error checking lock file: %s", str(e))
        # In case of unexpected errors, better to proceed than block the application
        return True


def remove_lock_file() -> bool:
    """
    Remove the lock file if it exists and belongs to this process.

    Returns:
        True if lock file was removed successfully, False otherwise
    """
    app_dirs = get_app_dirs()
    lock_file = app_dirs["runtime_dir"] / "battery-guardian.lock"

    if not lock_file.exists():
        return True

    try:
        # Read the PID from lock file
        with open(lock_file, "r", encoding="utf-8") as f:
            lock_pid = f.read().strip()

        # Check if the lock file belongs to this process
        current_pid = str(os.getpid())
        if lock_pid == current_pid:
            try:
                lock_file.unlink()
                logger.info("Lock file removed")
                return True
            except Exception as e:
                logger.error("Error removing lock file: %s", str(e))
                return False
        else:
            logger.warning(
                "Lock file exists but belongs to another process (PID %s vs current %s)",
                lock_pid,
                current_pid
            )
            # If this process is being run as root or with sufficient privileges,
            # we can try to clean up stale lock files
            if os.geteuid() == 0:
                try:
                    # Try to check if the process exists
                    try:
                        pid = int(lock_pid)
                        os.kill(pid, 0)
                        # Process exists, don't remove the lock
                        logger.warning(
                            "Process %d is still running, not removing its lock file", pid
                        )
                        return False
                    except (ValueError, OSError):
                        # Process doesn't exist, safe to remove the lock
                        lock_file.unlink()
                        logger.info("Removed stale lock file from non-existent process")
                        return True
                except Exception as e:
                    logger.error("Error checking process existence: %s", str(e))
            return False
    except (IOError, ValueError) as e:
        logger.error("Error reading lock file: %s", str(e))
        # Try to remove it anyway as a last resort
        try:
            lock_file.unlink()
            logger.info("Removed unreadable lock file")
            return True
        except Exception:
            pass
        return False


def get_sleep_duration(
    battery_percent: int, ac_status: str, has_changed: int, config: Dict[str, Any]
) -> int:
    """
    Calculate sleep duration based on current battery status and change detection.

    Implements adaptive back-off algorithm to reduce polling frequency when
    battery status is stable.

    Args:
        battery_percent: Current battery percentage
        ac_status: Current power source status
        has_changed: Flag indicating if status has changed (1 for yes, 0 for no)
        config: Application configuration

    Returns:
        Sleep duration in seconds
    """
    # Get default values from config
    backoff_initial = config.get("backoff_initial", 10)
    backoff_max = config.get("backoff_max", 300)
    backoff_factor = config.get("backoff_factor", 2)
    critical_polling = config.get("critical_polling", 30)
    critical_threshold = config.get("critical_threshold", 10)

    # For critical battery levels, use a more frequent polling
    if battery_percent <= critical_threshold:
        return critical_polling

    # Get stored sleep duration from shared state or start with initial value
    current_sleep = int(os.environ.get("BG_CURRENT_SLEEP", str(backoff_initial)))

    # Reset backoff if status has changed
    if has_changed == 1:
        new_sleep = backoff_initial
    else:
        # Otherwise increase the sleep duration (up to max)
        new_sleep = min(current_sleep * backoff_factor, backoff_max)

    # Store new sleep duration in environment for next call
    os.environ["BG_CURRENT_SLEEP"] = str(new_sleep)

    return new_sleep


def start_monitoring(config: Dict[str, Any], state: Dict[str, Any]) -> bool:
    """
    Attempt to start event-based monitoring (udev or other system events).

    Tries multiple approaches for battery monitoring in order of preference:
    1. Using dbus for UPower events (needs dbus-python and PyGObject packages)
    2. Using acpi_listen for ACPI events (needs acpid package)
    3. Using pyudev for udev events (needs pyudev package)

    Args:
        config: Application configuration
        state: Current state dictionary

    Returns:
        True if monitoring was successfully started, False otherwise
    """
    global MONITORING_THREADS

    # First try UPower/dbus method (most efficient, widely available on desktop environments)
    if _start_upower_monitoring(config, state):
        return True

    # Next try acpi_listen (commonly available on laptops)
    if _start_acpi_monitoring(config, state):
        return True

    # Finally try pyudev (fallback for Linux systems)
    if _start_pyudev_monitoring(config, state):
        return True

    # If we reach here, all event-based methods failed
    logger.warning(
        "Event-based monitoring is not available. To enable efficient monitoring, install:"
    )
    logger.info(
        "1. UPower with dbus-python and PyGObject: pip install dbus-python PyGObject"
    )
    logger.info(
        "2. acpid package: sudo apt-get install acpid (or equivalent for your distro)"
    )
    logger.info("3. pyudev package: pip install pyudev")
    logger.info(
        "You can use the install_dependencies.py script to install these dependencies easily:"
    )
    logger.info("  python install_dependencies.py events")
    return False  # Fall back to polling loop


def check_monitoring_threads() -> bool:
    """
    Check if any monitoring threads are still running.

    Returns:
        True if at least one monitoring thread is active, False otherwise
    """
    global MONITORING_THREADS

    # Filter out any dead threads
    MONITORING_THREADS = [t for t in MONITORING_THREADS if t.is_alive()]

    # Log monitoring status
    if not MONITORING_THREADS:
        logger.debug("No monitoring threads are currently active")
        return False
    else:
        logger.debug("%d monitoring threads are active", len(MONITORING_THREADS))
        return True


def force_exit_handler() -> None:
    """
    Force clean exit for zombie processes.
    This function is registered at import time and will be called
    when Python is finalizing (even in case of signals or system exit).
    """
    # Always try to clean up lock file on exit
    try:
        remove_lock_file()
    except Exception as e:
        # This may be called during interpreter shutdown when logging is not available
        # so just try a simple print
        try:
            print(f"Error cleaning up lock file during exit: {e}")
        except Exception:
            pass  # Give up if even print fails


# Register the force exit handler
atexit.register(force_exit_handler)


def _start_upower_monitoring(config: Dict[str, Any], state: Dict[str, Any]) -> bool:
    """
    Start UPower-based event monitoring for battery status changes.

    Args:
        config: Application configuration
        state: Current state dictionary

    Returns:
        True if monitoring was successfully started, False otherwise
    """
    try:
        # Import our dedicated UPower monitor module
        from .upower import initialize_upower_monitoring

        logger.info("Attempting to use UPower for event-based monitoring")
        
        # Define a callback to process UPower events
        def process_battery_event(battery_percent: int, ac_status: str) -> None:
            try:
                # Import these here to avoid circular imports
                from ..modules.brightness import adjust_brightness
                from ..modules.notification import notify_status_change
                
                # Previous values
                prev_battery_percent = state.get("battery_percent", 0)
                prev_ac_status = state.get("ac_status", "Unknown")
                
                # Update shared state
                new_state = {
                    "battery_percent": battery_percent,
                    "ac_status": ac_status,
                    "previous_battery_percent": prev_battery_percent,
                    "previous_ac_status": prev_ac_status,
                }
                
                # Check for changes requiring notifications
                notify_status_change(
                    battery_percent,
                    prev_battery_percent,
                    ac_status,
                    prev_ac_status,
                    config,
                )
                
                # Adjust screen brightness based on battery status
                if config.get("brightness_control_enabled", True):
                    adjust_brightness(battery_percent, ac_status, config)
                
                # Update state for next comparison
                state.update(new_state)
                
                logger.debug(
                    "Processed power event: battery=%d%%, AC=%s",
                    battery_percent,
                    ac_status,
                )
            except Exception as e:
                logger.exception("Error processing power event: %s", e)

        # Initialize UPower monitoring with our callback
        success = initialize_upower_monitoring(process_battery_event, state)
        
        if success:
            logger.info("Successfully started UPower monitoring")
            return True
        else:
            logger.warning("Failed to initialize UPower monitoring")
            return False
                
                # Try systemd-logind as fallback
                if not success:
                    try:
                        bus.add_signal_receiver(
                            power_signal_handler,
                            dbus_interface="org.freedesktop.login1.Manager",
                            signal_name="PrepareForSleep",
                        )
                        logger.info("Connected to systemd-logind D-Bus signals")
                        success = True
                    except Exception as e:
                        logger.warning("Failed to connect to systemd-logind signals: %s", e)
                        return False
                
                if not success:
                    logger.warning("Failed to connect to any power-related D-Bus signals")
                    return False
                
                # Start the main loop
                loop = GLib.MainLoop()
                loop.run()
                
            except Exception as e:
                logger.exception("Error in GLib main loop thread: %s", e)
                return False
            finally:
                logger.info("GLib main loop thread exiting")
                # Make sure the monitor thread knows to exit too
                thread_running.clear()
        
        # Start the GLib main loop in a separate thread
        glib_thread = threading.Thread(target=glib_main_loop, daemon=True)
        glib_thread.start()
        
        # Register both threads for monitoring
        MONITORING_THREADS.append(monitor_thread)
        MONITORING_THREADS.append(glib_thread)
        
        # Wait a bit to ensure everything is started
        time.sleep(2)
        
        # Check if both threads are still running
        if monitor_thread.is_alive() and glib_thread.is_alive():
            logger.info("Successfully started UPower battery monitoring")
            # Trigger initial event to update status
            power_event.set()
            return True
        else:
            logger.warning("UPower monitoring thread failed to start")
            # Cleanup if something failed
            thread_running.clear()
            return False
            
    except ImportError:
        logger.warning("dbus-python or PyGObject packages are not installed")
        logger.info(
            "To enable UPower monitoring, install: pip install dbus-python PyGObject"
        )
    except Exception as e:
        logger.warning("Failed to set up UPower monitoring: %s", str(e))
        
    return False


def _start_acpi_monitoring(config: Dict[str, Any], state: Dict[str, Any]) -> bool:
    """
    Start ACPI event-based monitoring for battery status changes.

    Args:
        config: Application configuration
        state: Current state dictionary

    Returns:
        True if monitoring was successfully started, False otherwise
    """
    if check_command_exists("acpi_listen"):
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
                                    from ..modules.battery import check_battery_status
                                    from ..modules.brightness import adjust_brightness
                                    from ..modules.notification import (
                                        notify_status_change,
                                    )

                                    battery_percent, ac_status = check_battery_status()

                                    # Update state
                                    new_state = {
                                        "battery_percent": battery_percent,
                                        "ac_status": ac_status,
                                        "previous_battery_percent": state.get(
                                            "battery_percent", 0
                                        ),
                                        "previous_ac_status": state.get(
                                            "ac_status", "Unknown"
                                        ),
                                    }

                                    # Check for changes requiring notifications
                                    notify_status_change(
                                        battery_percent,
                                        state.get("battery_percent", 0),
                                        ac_status,
                                        state.get("ac_status", "Unknown"),
                                        config,
                                    )

                                    # Adjust screen brightness based on battery status
                                    if config.get("brightness_control_enabled", True):
                                        adjust_brightness(
                                            battery_percent, ac_status, config
                                        )

                                    # Update state for next comparison
                                    state.update(new_state)

                                    logger.debug(
                                        "Processed ACPI event: battery=%d%%, AC=%s",
                                        battery_percent,
                                        ac_status,
                                    )
                                except Exception as e:
                                    logger.error(
                                        "Error processing ACPI event: %s", str(e)
                                    )
                    except KeyboardInterrupt:
                        logger.info("ACPI monitoring interrupted")
                    finally:
                        # Clean up the process
                        process.terminate()
                        process.wait(timeout=2)

                    # If we get here normally, acpi_listen has terminated
                    logger.warning("acpi_listen process terminated unexpectedly")

                except Exception as e:
                    logger.error("Error in ACPI monitoring thread: %s", str(e))

            # Start the monitoring in a separate thread
            thread = threading.Thread(target=monitor_acpi_events, daemon=True)
            thread.start()
            MONITORING_THREADS.append(thread)

            # Give it a moment to initialize and check if it's still running
            time.sleep(1)
            if thread.is_alive():
                logger.info("Successfully started ACPI battery monitoring")
                return True
            else:
                logger.warning("ACPI monitoring thread failed to start")

        except Exception as e:
            logger.warning("Failed to set up acpi_listen monitoring: %s", str(e))
    else:
        logger.warning("acpi_listen command not found, cannot use ACPI monitoring")

    return False


def _start_pyudev_monitoring(config: Dict[str, Any], state: Dict[str, Any]) -> bool:
    """
    Start pyudev-based monitoring for battery status changes.

    Args:
        config: Application configuration
        state: Current state dictionary

    Returns:
        True if monitoring was successfully started, False otherwise
    """
    try:
        import pyudev

        logger.info("Attempting to use pyudev for event-based monitoring")

        # Create a function to handle udev events
        def monitor_udev_events():
            try:
                context = pyudev.Context()
                monitor = pyudev.Monitor.from_netlink(context)
                monitor.filter_by(subsystem="power_supply")

                logger.info("Starting udev power supply monitor")

                # This will block and process events
                try:
                    for device in iter(monitor.poll, None):
                        if (
                            device.get("POWER_SUPPLY_ONLINE", None) is not None
                            or device.get("POWER_SUPPLY_STATUS", None) is not None
                        ):
                            try:
                                # Process battery event, update state and adjust brightness
                                from ..modules.battery import check_battery_status
                                from ..modules.brightness import adjust_brightness
                                from ..modules.notification import notify_status_change

                                battery_percent, ac_status = check_battery_status()

                                # Update state
                                new_state = {
                                    "battery_percent": battery_percent,
                                    "ac_status": ac_status,
                                    "previous_battery_percent": state.get(
                                        "battery_percent", 0
                                    ),
                                    "previous_ac_status": state.get(
                                        "ac_status", "Unknown"
                                    ),
                                }

                                # Check for changes requiring notifications
                                notify_status_change(
                                    battery_percent,
                                    state.get("battery_percent", 0),
                                    ac_status,
                                    state.get("ac_status", "Unknown"),
                                    config,
                                )

                                # Adjust screen brightness based on battery status
                                if config.get("brightness_control_enabled", True):
                                    adjust_brightness(
                                        battery_percent, ac_status, config
                                    )

                                # Update state for next comparison
                                state.update(new_state)

                                logger.debug(
                                    "Processed udev event: battery=%d%%, AC=%s",
                                    battery_percent,
                                    ac_status,
                                )
                            except Exception as e:
                                logger.error("Error processing udev event: %s", str(e))
                except KeyboardInterrupt:
                    logger.info("Udev monitoring interrupted")
            except Exception as e:
                logger.error("Error in udev monitoring thread: %s", str(e))

        # Start the monitoring in a separate thread
        thread = threading.Thread(target=monitor_udev_events, daemon=True)
        thread.start()
        MONITORING_THREADS.append(thread)

        # Give it a moment to initialize and check if it's still running
        time.sleep(1)
        if thread.is_alive():
            logger.info("Successfully started pyudev battery monitoring")
            return True
        else:
            logger.warning("pyudev monitoring thread failed to start")
    except ImportError:
        logger.warning("pyudev package is not installed")
        logger.info("To enable pyudev monitoring, install: pip install pyudev")
    except Exception as e:
        logger.warning(f"Failed to set up pyudev monitoring: {e}")

    return False
