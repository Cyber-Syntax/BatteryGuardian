#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring and management tool.

Configuration management module.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import json
import os
import sys
from typing import TypedDict

# Import yaml if available
try:
    import yaml
except ImportError:
    yaml = None

from .log import get_app_dirs, get_logger


# Type hint for configuration dictionary
class Config(TypedDict, total=False):
    """Type definition for configuration dictionary."""

    low_threshold: int
    critical_threshold: int
    full_battery_threshold: int
    battery_almost_full_threshold: int
    notification_cooldown: int
    brightness_control_enabled: bool
    brightness_max: int
    brightness_very_high: int
    brightness_high: int
    brightness_medium_high: int
    brightness_medium: int
    brightness_medium_low: int
    brightness_low: int
    brightness_very_low: int
    brightness_critical: int
    backoff_initial: int
    backoff_max: int
    backoff_factor: int
    critical_polling: int
    dbus_test_timeout: int
    battery_very_high_threshold: int
    battery_high_threshold: int
    battery_medium_high_threshold: int
    battery_medium_threshold: int
    battery_medium_low_threshold: int
    battery_low_threshold: int


# Initialize logger
logger = get_logger(__name__)


def get_default_config() -> Config:
    """
    Get default configuration values.

    Returns:
        Dictionary with default configuration
    """
    return {
        # Battery thresholds
        "low_threshold": 20,
        "critical_threshold": 10,
        "full_battery_threshold": 90,
        "battery_almost_full_threshold": 85,
        # Notification settings
        "notification_cooldown": 300,  # seconds between identical notifications
        # Brightness Control Configuration
        "brightness_control_enabled": True,
        "brightness_max": 100,  # Maximum brightness (for AC power)
        "brightness_very_high": 95,  # For battery >85%
        "brightness_high": 85,  # For battery >70%
        "brightness_medium_high": 70,  # For battery >60%
        "brightness_medium": 60,  # For battery >50%
        "brightness_medium_low": 45,  # For battery >30%
        "brightness_low": 35,  # For battery >20%
        "brightness_very_low": 25,  # For battery >10%
        "brightness_critical": 15,  # For critical battery <=10%
        # Adaptive polling settings (in seconds)
        "backoff_initial": 10,  # Initial polling interval
        "backoff_max": 300,  # Maximum polling interval (5 minutes)
        "backoff_factor": 2,  # Multiplier for each step (exponential growth)
        "critical_polling": 30,  # Always poll at least this often when battery critical (<= 5%)
        "dbus_test_timeout": 5,  # Seconds to test dbus connection
        # Battery thresholds for brightness changes
        "battery_very_high_threshold": 85,  # Almost full battery
        "battery_high_threshold": 70,
        "battery_medium_high_threshold": 60,
        "battery_medium_threshold": 50,
        "battery_medium_low_threshold": 30,
        "battery_low_threshold": 20,
        # Critical threshold is defined above
    }


def ensure_user_config_exists() -> None:
    """Create a default user configuration file if none exists."""
    app_dirs = get_app_dirs()
    config_dir = app_dirs["config_dir"]

    # Try different config file formats in order of preference
    config_paths = [
        config_dir / "config.yaml",
        config_dir / "config.json",
        config_dir / "config.py",
    ]

    # Check if any config file exists
    if any(path.exists() for path in config_paths):
        return

    # Create default YAML configuration
    config_file = config_paths[0]  # Use YAML as default format
    try:
        # Get default config
        default_config = get_default_config()

        # Create config directory if it doesn't exist
        config_dir.mkdir(parents=True, exist_ok=True)

        # Write default config with comments
        with open(config_file, "w") as f:
            f.write("# BatteryGuardian Configuration File\n")
            f.write(
                "# Adjust settings below to customize battery monitoring behavior\n\n"
            )
            yaml.dump(default_config, f, default_flow_style=False, sort_keys=False)

        logger.info(f"Created default configuration at {config_file}")
    except (IOError, OSError) as e:
        logger.error(f"Failed to create default configuration: {e}")


def load_config() -> Config:
    """
    Load configuration from various sources.

    Returns:
        Dictionary with merged configuration
    """
    # Start with default configuration
    config = get_default_config()

    # Ensure user config directory exists
    app_dirs = get_app_dirs()
    config_dir = app_dirs["config_dir"]

    # Try to load user configuration
    config_loaded = False

    # Check for YAML config
    yaml_config = config_dir / "config.yaml"
    if yaml_config.exists():
        try:
            with open(yaml_config, "r") as f:
                user_config = yaml.safe_load(f)
                if isinstance(user_config, dict):
                    config.update(user_config)
                    logger.info(f"Loaded configuration from {yaml_config}")
                    config_loaded = True
        except Exception as e:
            logger.error(f"Failed to load YAML configuration: {e}")

    # Check for JSON config
    if not config_loaded:
        json_config = config_dir / "config.json"
        if json_config.exists():
            try:
                with open(json_config, "r") as f:
                    user_config = json.load(f)
                    config.update(user_config)
                    logger.info(f"Loaded configuration from {json_config}")
                    config_loaded = True
            except Exception as e:
                logger.error(f"Failed to load JSON configuration: {e}")

    # Check for Python config
    if not config_loaded:
        py_config = config_dir / "config.py"
        if py_config.exists():
            try:
                # Add directory containing config.py to path so we can import it
                sys.path.insert(0, str(config_dir))
                import config as user_config_module

                sys.path.pop(0)  # Remove the added path

                # Extract variables from the module
                user_config = {
                    k: v
                    for k, v in vars(user_config_module).items()
                    if not k.startswith("__")
                }
                config.update(user_config)
                logger.info(f"Loaded configuration from {py_config}")
                config_loaded = True
            except Exception as e:
                logger.error(f"Failed to load Python configuration: {e}")

    # Create default config if none found
    if not config_loaded:
        ensure_user_config_exists()
        logger.info("Using default configuration")

    # Override with environment variables
    for key in config:
        env_var = f"BG_{key.upper()}"
        if env_var in os.environ:
            value = os.environ[env_var]

            # Convert to appropriate type
            if isinstance(config[key], bool):
                config[key] = value.lower() in ("true", "yes", "1")
            elif isinstance(config[key], int):
                try:
                    config[key] = int(value)
                except ValueError:
                    pass
            elif isinstance(config[key], float):
                try:
                    config[key] = float(value)
                except ValueError:
                    pass
            else:
                config[key] = value

            logger.debug(f"Config override from environment: {key}={config[key]}")

    return config
