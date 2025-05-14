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

    except ImportError:
        logger.warning("dbus-python or PyGObject packages are not installed")
        logger.info(
            "To enable UPower monitoring, install: pip install dbus-python PyGObject"
        )
        return False
    except Exception as e:
        logger.warning(f"Failed to set up UPower monitoring: {e}")
        return False
