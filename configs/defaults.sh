#!/usr/bin/env bash
# BatteryGuardian Default Configuration
# This file contains default configuration values for BatteryGuardian
# Users can override these settings in their local configuration

# Battery thresholds
bg_LOW_THRESHOLD=20
bg_CRITICAL_THRESHOLD=10
bg_FULL_BATTERY_THRESHOLD=90
bg_BATTERY_ALMOST_FULL_THRESHOLD=85

# Notification settings
bg_NOTIFICATION_COOLDOWN=300  # seconds between identical notifications

# Brightness Control Configuration
bg_BRIGHTNESS_CONTROL_ENABLED=true
bg_BRIGHTNESS_MAX=100        # Maximum brightness (for AC power)
bg_BRIGHTNESS_VERY_HIGH=95   # For battery >85%
bg_BRIGHTNESS_HIGH=85        # For battery >70%
bg_BRIGHTNESS_MEDIUM_HIGH=70 # For battery >60%
bg_BRIGHTNESS_MEDIUM=60      # For battery >50%
bg_BRIGHTNESS_MEDIUM_LOW=45  # For battery >30%
bg_BRIGHTNESS_LOW=35         # For battery >20%
bg_BRIGHTNESS_VERY_LOW=25    # For battery >10%
bg_BRIGHTNESS_CRITICAL=15    # For critical battery <=10%

# Battery thresholds for brightness changes
bg_BATTERY_VERY_HIGH_THRESHOLD=85 # Almost full battery
bg_BATTERY_HIGH_THRESHOLD=70
bg_BATTERY_MEDIUM_HIGH_THRESHOLD=60
bg_BATTERY_MEDIUM_THRESHOLD=50
bg_BATTERY_MEDIUM_LOW_THRESHOLD=30
bg_BATTERY_LOW_THRESHOLD=20
# Critical threshold is already defined above