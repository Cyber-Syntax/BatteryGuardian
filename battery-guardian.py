#!/usr/bin/env python3
"""
Launcher for BatteryGuardian.

This script ensures the application is run correctly from any location.
"""

import sys
from pathlib import Path

# Add the parent directory to the Python path
script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir))

if __name__ == "__main__":
    # Import and run the main function
    from src import main

    main()

if __name__ == "__main__":
    main()
