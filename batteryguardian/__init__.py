#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Initialization file for BatteryGuardian Python port.

This file exports the main components from the modules.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

# Import and re-export modules to make them easily accessible
from .main import main

# Make main function the default entry point
if __name__ == "__main__":
    main()
