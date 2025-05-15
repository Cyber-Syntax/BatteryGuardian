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

# Check for command-line arguments
if __name__ == "__main__":
    # Check if we're being asked to clean up lock files
    if len(sys.argv) > 1 and sys.argv[1] in ["cleanup", "clean", "remove-lock"]:
        # Import and directly call the lock file cleanup function
        from src.modules.utils import get_app_dirs

        # Remove lock file if it exists
        app_dirs = get_app_dirs()
        lock_file = app_dirs["runtime_dir"] / "battery-guardian.lock"

        if lock_file.exists():
            try:
                lock_file.unlink()
                print(f"Successfully removed lock file: {lock_file}")
            except (PermissionError, FileNotFoundError) as e:
                print(f"Error removing lock file: {e}")
                sys.exit(1)
        else:
            print("No lock file found. Already clean.")
        sys.exit(0)

    # Normal execution - import and run the main function
    from src.main import main

    # Call the main() function from the imported main module
    main()
