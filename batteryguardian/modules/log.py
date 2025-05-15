#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Battery monitoring and management tool.

Logging module - provides logging functionality.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

import logging
import os
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Dict

# ---- Constants ----
# Maximum log size in bytes (1MB)
MAX_LOG_SIZE: int = 1024 * 1024
# Maximum number of backup log files
MAX_LOG_COUNT: int = 3


def get_app_dirs() -> Dict[str, Path]:
    """
    Set up application directories based on XDG specifications.

    Returns:
        Dictionary with paths to config, state, and runtime directories.
    """
    # Set XDG directories with fallbacks
    xdg_config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    xdg_state_home = Path(
        os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")
    )
    xdg_runtime_dir = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))

    # Application-specific directories
    bg_config_dir = xdg_config_home / "battery-guardian"
    bg_state_dir = xdg_state_home / "battery-guardian"
    bg_runtime_dir = xdg_runtime_dir / "battery-guardian"

    # Create necessary directories
    for directory in (bg_config_dir, bg_state_dir / "logs", bg_runtime_dir):
        try:
            directory.mkdir(parents=True, exist_ok=True)
        except (PermissionError, FileNotFoundError):
            # Fall back to /tmp if XDG directories can't be created
            if directory == bg_runtime_dir:
                bg_runtime_dir = Path("/tmp/battery-guardian")
                bg_runtime_dir.mkdir(parents=True, exist_ok=True)

    return {
        "config_dir": bg_config_dir,
        "state_dir": bg_state_dir,
        "runtime_dir": bg_runtime_dir,
        "log_dir": bg_state_dir / "logs",
    }


def setup_logging(level: int = logging.INFO) -> None:
    """
    Set up logging configuration for the application.

    Args:
        level: Logging level (default: INFO)
    """
    app_dirs = get_app_dirs()
    log_file = app_dirs["log_dir"] / "battery-guardian.log"

    # Define log format
    log_format = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    date_format = "%Y-%m-%d %H:%M:%S"

    # Configure the root logger
    logging.basicConfig(
        level=level,
        format=log_format,
        datefmt=date_format,
        handlers=[
            # Console handler
            logging.StreamHandler(sys.stdout),
            # File handler with rotation
            RotatingFileHandler(
                log_file,
                maxBytes=MAX_LOG_SIZE,
                backupCount=MAX_LOG_COUNT,
                encoding="utf-8",
            ),
        ],
    )


def get_logger(name: str) -> logging.Logger:
    """
    Get a logger instance for the specified module.

    Args:
        name: Name of the module requesting the logger

    Returns:
        Logger instance configured for the module
    """
    return logging.getLogger(name)
