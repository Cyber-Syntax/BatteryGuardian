# BatteryGuardian

A comprehensive battery monitoring and management solution for Linux systems. BatteryGuardian actively monitors your laptop's battery status and takes intelligent actions to both inform users and extend battery life.

## Features

- **Battery Level Notifications**: Alerts for low, critical, and full battery levels
- **Smart Brightness Control**: Automatically adjusts screen brightness based on battery level and charging status
- **Multi-Environment Compatibility**: Works across different window managers (Hyprland, i3, Qtile, XFCE, etc.)
- **Ultra-Fast Event Monitoring**: Instantaneous reactions to power events (like AC adapter changes) using optimized monitoring techniques
- **Multiple Fallback Methods**: Uses various methods to detect battery status and control brightness
- **Adaptive Polling**: Exponential back-off algorithm that minimizes CPU wakeups while staying responsive
- **Customizable Thresholds**: Configure your own battery thresholds and brightness levels
- **Resource Efficient**: Prioritizes events over polling, resets back-off timers when actual changes occur
- **Automatic Configuration**: Creates user-specific configuration files for easy customization
- **Log Rotation**: Maintains log files with automatic rotation (3 files of max 1MB each)
- **XDG Base Directory Support**: Properly uses XDG directories for configuration and logs

## Prerequisites

Before using BatteryGuardian, ensure you have the following:

1. **Notification System**:

   - A notification daemon like `dunst`, `mako`, or any other that works with `notify-send`

2. **Brightness Control** (at least one of these):

   - `brightnessctl` (recommended)
   - `light`
   - `xbacklight` (for X11 environments)
   - Direct sysfs access (automatic fallback)

3. **Optional for Event-Based Monitoring** (at least one of these):
   - `pyudev` (Python package)
   - `dbus-python` and `PyGObject` (Python packages)
   - `acpid` (system package)

## Installation

### Basic Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/cyber-syntax/BatteryGuardian.git
   cd BatteryGuardian
   ```

2. Make the launcher script executable:

   ```bash
   chmod +x battery-guardian.py
   ```

3. Install core dependencies:
   ```bash
   pip install -r requirements.txt
   ```

### Enhanced Installation (Recommended)

For the best experience with event-based monitoring (lower resource usage):

1. Use our dependency installer script:

   ```bash
   ./install_dependencies.py all
   ```

   This will install both Python packages and system dependencies necessary for event-based monitoring.

## Usage

### Running BatteryGuardian

Simply execute the launcher script:

```bash
./battery-guardian.py
```

For automatic startup, add the script to your window manager or desktop environment's autostart configuration.

### Configuration

BatteryGuardian creates a configuration file at first run:

- `~/.config/battery-guardian/config.yaml`

You can edit this file to customize thresholds, brightness levels, and other settings.

## How It Works

BatteryGuardian uses multiple methods to monitor your battery:

1. **Event-Based Monitoring**: If available dependencies are installed, it will use one of:

   - Linux kernel udev events via `pyudev`
   - DBus signals via `dbus-python`
   - ACPI events via `acpi_listen`

2. **Fallback Polling**: If event-based monitoring is not available, it uses an adaptive polling strategy that:
   - Checks more frequently when the battery status changes
   - Gradually increases sleep intervals when the status is stable
   - Always checks frequently when battery level is critical

## Choosing Between Bash and Python Versions

This repository contains both the original bash implementation and a Python port:

- **Bash version**: Located in `src/main.sh` and other `.sh` files

  - Advantages: No Python dependencies, potentially lower resource usage
  - Limitations: More complex logic in bash, less modular

- **Python version**: Located in `src/main.py` and other `.py` files
  - Advantages: More maintainable, better error handling, event-based monitoring
  - Requirements: Python 3.6+ and optional dependencies

Choose the version that best fits your needs and system configuration.

3. The script will create the necessary configuration directories automatically when first run.

## Configuration for Different Environments

### X11-based environments (i3, Qtile, etc.)

For X11-based window managers, if you want to use `xbacklight` without sudo:

1. Create a udev rule file:

   ```bash
   sudo nano /etc/udev/rules.d/90-backlight.rules
   ```

2. Add the following content:

   ```
   ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
   ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
   ```

3. Add your user to the video group:

   ```bash
   sudo usermod -a -G video $USER
   ```

4. Reboot or reload udev rules:
   ```bash
   sudo udevadm control --reload-rules && sudo udevadm trigger
   ```

### Autostart Configuration

#### Hyprland

Add to your `~/.config/hypr/hyprland.conf`:

```
exec-once = /path/to/BatteryGuardian/src/battery_guardian.sh
```

#### i3

Add to your `~/.config/i3/config`:

```
exec --no-startup-id /path/to/BatteryGuardian/src/battery_guardian.sh
```

#### Qtile

Add to your `~/.config/qtile/config.py`:

```python
@hook.subscribe.startup_once
def autostart():
    subprocess.Popen(['/path/to/BatteryGuardian/src/battery_guardian.sh'])
```

## Usage

The script runs in the background and automatically:

- Sends notifications when battery reaches low, critical, or full levels
- Adjusts screen brightness based on battery level when discharging
- Sets higher brightness when connected to AC power
- Adapts check frequency based on battery status

## Customization

When you first run BatteryGuardian, it automatically creates a configuration file at `~/.config/battery-guardian/config.sh`. You can edit this file to customize all aspects of the script's behavior:

```bash
# Example customizations:

# Battery thresholds
bg_LOW_THRESHOLD=25  # Set low battery threshold to 25%
bg_CRITICAL_THRESHOLD=15  # Set critical battery threshold to 15%

# Brightness levels
bg_BRIGHTNESS_CONTROL_ENABLED=true
bg_BRIGHTNESS_MAX=90  # Set maximum brightness to 90%
bg_BRIGHTNESS_VERY_LOW=30  # Set very low brightness to 30%
```

The configuration file contains documentation for all available settings.

## Logs

BatteryGuardian stores logs in `~/.local/state/battery-guardian/logs/` with automatic log rotation to prevent excessive disk usage:

- Logs are automatically rotated when they reach 1MB in size
- The system maintains up to 3 log files (battery.log, battery.log.1, battery.log.2, battery.log.3)
- Oldest logs are automatically removed

## Troubleshooting

### No Notifications

- Check if your notification daemon is running
- Verify permissions for `notify-send`

### Brightness Control Not Working

- Check which brightness control method is available: `which brightnessctl light xbacklight`
- Verify permissions for brightness files: `ls -la /sys/class/backlight/*/brightness`
- For X11-based WMs, ensure the udev rules are properly set

### High CPU Usage

- Check if multiple instances are running: `ps aux | grep battery_guardian`
- Check the log file for errors

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the BSD 3-Clause License - see the LICENSE file for details.
