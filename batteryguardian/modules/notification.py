#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring and management tool.

Notification functions module.
Author: Cyber-Syntax
License: BSD 3-Clause License

This module provides desktop notifications with performance optimizations:
1. Asynchronous notification dispatch using thread pool
2. Notification throttling to prevent alert flooding
3. Timeouts on subprocess calls to prevent hanging
"""

import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, Optional

from .log import get_logger

# Initialize logger
logger = get_logger(__name__)

# Global throttling variables
LAST_NOTIFICATION: Dict[str, float] = {}

# Thread pool for async notifications
# Use a small pool size to avoid creating too many threads
_NOTIFICATION_EXECUTOR = ThreadPoolExecutor(
    max_workers=2, thread_name_prefix="NotifyWorker"
)

# Maximum time to wait for a notification command in seconds
NOTIFICATION_TIMEOUT: int = 2


def _send_notification_sync(
    title: str, message: str, urgency: str = "normal", icon: Optional[str] = None
) -> bool:
    """
    Send a desktop notification synchronously using notify-send.

    This is an internal implementation function that runs the actual subprocess.
    Use send_notification() instead for async notifications.

    Args:
        title: Notification title
        message: Notification message body
        urgency: Notification urgency ("low", "normal", "critical")
        icon: Icon name or path to image

    Returns:
        True if notification was sent successfully, False otherwise
    """
    cmd = ["notify-send"]

    # Add urgency
    cmd.extend(["-u", urgency])

    # Add icon if provided
    if icon:
        cmd.extend(["-i", icon])

    # Add title and message
    cmd.extend([title, message])

    try:
        # Add timeout to prevent hanging
        subprocess.run(cmd, check=True, timeout=NOTIFICATION_TIMEOUT)
        logger.debug(f"Sent notification: {title}")
        return True
    except subprocess.TimeoutExpired:
        logger.error(
            f"Notification timed out after {NOTIFICATION_TIMEOUT} seconds: {title}"
        )
        return False
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        logger.error(f"Failed to send notification: {e}")
        return False


def send_notification(
    title: str, message: str, urgency: str = "normal", icon: Optional[str] = None
) -> bool:
    """
    Send a desktop notification asynchronously using notify-send.

    This function returns immediately and processes the notification in a background
    thread pool to avoid blocking the main application.

    Args:
        title: Notification title
        message: Notification message body
        urgency: Notification urgency ("low", "normal", "critical")
        icon: Icon name or path to image

    Returns:
        True if notification dispatch was initiated successfully
    """
    # Submit the notification to the thread pool
    try:
        _NOTIFICATION_EXECUTOR.submit(
            _send_notification_sync, title, message, urgency, icon
        )
        return True
    except Exception as e:
        logger.error(f"Failed to queue notification: {e}")
        # Fall back to synchronous notification if thread pool fails
        return _send_notification_sync(title, message, urgency, icon)


def should_throttle(notification_type: str, config: Dict[str, Any]) -> bool:
    """
    Check if a notification should be throttled based on cooldown period.

    Args:
        notification_type: Type of notification to check
        config: Application configuration

    Returns:
        True if notification should be throttled, False otherwise
    """
    cooldown = config.get("notification_cooldown", 300)  # Default to 5 minutes
    current_time = time.time()

    # Check if this type has been sent recently
    if notification_type in LAST_NOTIFICATION:
        last_time = LAST_NOTIFICATION[notification_type]
        if current_time - last_time < cooldown:
            logger.debug(
                f"Throttling {notification_type} notification (cooldown: {cooldown}s)"
            )
            return True

    # Update last notification time
    LAST_NOTIFICATION[notification_type] = current_time
    return False


def notify_status_change(
    battery_percent: int,
    previous_battery_percent: int,
    ac_status: str,
    previous_ac_status: str,
    config: Dict[str, Any],
) -> None:
    """
    Send notifications about battery status changes.

    Args:
        battery_percent: Current battery percentage
        previous_battery_percent: Previous battery percentage
        ac_status: Current power status
        previous_ac_status: Previous power status
        config: Application configuration
    """
    # Load thresholds from config
    critical_threshold = config.get("critical_threshold", 10)
    low_threshold = config.get("low_threshold", 20)
    full_threshold = config.get("full_battery_threshold", 90)

    # Check critical battery condition
    if (
        battery_percent <= critical_threshold
        and previous_battery_percent > critical_threshold
    ):
        if not should_throttle("critical", config):
            send_notification(
                "Critical Battery Warning",
                f"Battery at {battery_percent}%. Connect charger now!",
                "critical",
                "battery-caution",
            )

    # Check low battery condition
    elif (
        battery_percent <= low_threshold
        and battery_percent > critical_threshold
        and previous_battery_percent > low_threshold
    ):
        if not should_throttle("low", config):
            send_notification(
                "Low Battery Warning",
                f"Battery at {battery_percent}%. Consider connecting charger.",
                "normal",
                "battery-low",
            )

    # Check full battery on AC
    elif (
        battery_percent >= full_threshold
        and previous_battery_percent < full_threshold
        and ac_status == "Connected"
    ):
        if not should_throttle("full", config):
            send_notification(
                "Battery Fully Charged",
                f"Battery at {battery_percent}%. Consider unplugging charger.",
                "normal",
                "battery-full-charged",
            )

    # Notify on AC connection/disconnection
    # For AC status changes, we want immediate notifications (no throttling)
    if ac_status != previous_ac_status:
        if ac_status == "Connected":
            # AC connected notifications should always show immediately
            send_notification(
                "AC Power Connected",
                f"Battery at {battery_percent}% and charging.",
                "low",
                "battery-good-charging",
            )
            # Update the last notification time to prevent repeated notifications
            # if another status check happens very soon
            LAST_NOTIFICATION["ac_connected"] = time.time()
        elif ac_status == "Disconnected" and previous_ac_status == "Connected":
            # AC disconnected notifications should always show immediately
            send_notification(
                "AC Power Disconnected",
                f"Battery at {battery_percent}%. Running on battery power.",
                "low",
                "battery",
            )
            # Update the last notification time to prevent repeated notifications
            LAST_NOTIFICATION["ac_disconnected"] = time.time()


def send_battery_notification(
    battery_percent: int, ac_status: str, message_type: str, config: Dict[str, Any]
) -> None:
    """
    Send a battery status notification.

    Args:
        battery_percent: Current battery percentage
        ac_status: Current power status
        message_type: Type of notification ("critical", "low", "full", etc.)
        config: Application configuration
    """
    if should_throttle(message_type, config):
        return

    if message_type == "critical":
        send_notification(
            "Critical Battery Warning",
            f"Battery at {battery_percent}%. Connect charger now!",
            "critical",
            "battery-caution",
        )
    elif message_type == "low":
        send_notification(
            "Low Battery Warning",
            f"Battery at {battery_percent}%. Consider connecting charger.",
            "normal",
            "battery-low",
        )
    elif message_type == "full":
        send_notification(
            "Battery Fully Charged",
            f"Battery at {battery_percent}%. Consider unplugging charger.",
            "normal",
            "battery-full-charged",
        )
    elif message_type == "status":
        charging_status = "charging" if ac_status == "Connected" else "discharging"
        send_notification(
            "Battery Status",
            f"Battery at {battery_percent}% and {charging_status}.",
            "low",
            "battery",
        )
