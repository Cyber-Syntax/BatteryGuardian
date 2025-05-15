#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring and management tool.

Notification functions module.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import subprocess
import time
from typing import Any, Dict, Optional

from .log import get_logger

# Initialize logger
logger = get_logger(__name__)

# Global throttling variables
LAST_NOTIFICATION: Dict[str, float] = {}


def send_notification(
    title: str, message: str, urgency: str = "normal", icon: Optional[str] = None
) -> bool:
    """
    Send a desktop notification using notify-send.

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
        subprocess.run(cmd, check=True)
        logger.debug(f"Sent notification: {title}")
        return True
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        logger.error(f"Failed to send notification: {e}")
        return False


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
    if ac_status != previous_ac_status:
        if ac_status == "Connected":
            if not should_throttle("ac_connected", config):
                send_notification(
                    "AC Power Connected",
                    f"Battery at {battery_percent}% and charging.",
                    "low",
                    "battery-good-charging",
                )
        elif ac_status == "Disconnected" and previous_ac_status == "Connected":
            if not should_throttle("ac_disconnected", config):
                send_notification(
                    "AC Power Disconnected",
                    f"Battery at {battery_percent}%. Running on battery power.",
                    "low",
                    "battery",
                )


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
