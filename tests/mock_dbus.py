#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryGuardian - Fast Power Monitor Tests - Mock DBus Helpers.

This module provides mock classes for DBus used in testing.
Author: Cyber-Syntax
License: BSD 3-Clause License
"""

from unittest import mock


class MockDBusMainLoop:
    """Mock for DBusGMainLoop."""

    def __init__(self, set_as_default=False):
        self.set_as_default = set_as_default


class MockGLib:
    """Mock for GLib."""

    class MainLoop:
        """Mock for GLib.MainLoop."""

        def __init__(self):
            pass

        def run(self):
            pass


class MockSystemBus:
    """Mock for dbus.SystemBus."""

    def __init__(self):
        self.signal_receivers = []

    def get_object(self, service, path):
        """Return a mock object."""
        mock_obj = mock.MagicMock()
        if path == "/org/freedesktop/UPower":
            mock_obj.EnumerateDevices = lambda: [
                "/org/freedesktop/UPower/devices/ac_adapter"
            ]
        return mock_obj

    def add_signal_receiver(self, handler, **kwargs):
        """Mock adding a signal receiver."""
        self.signal_receivers.append((handler, kwargs))


class MockDBus:
    """Mock for dbus module."""

    class SystemBus:
        """Mock for dbus.SystemBus."""

        def __init__(self):
            pass

        def get_object(self, service, path):
            """Return a mock object."""
            mock_obj = mock.MagicMock()
            if path == "/org/freedesktop/UPower":
                mock_obj.EnumerateDevices = lambda: [
                    "/org/freedesktop/UPower/devices/ac_adapter"
                ]
            return mock_obj

    class Interface:
        """Mock for dbus.Interface."""

        def __init__(self, obj, interface_name):
            self.obj = obj
            self.interface_name = interface_name

    class DBusException(Exception):
        """Mock for dbus.DBusException."""

        pass


class MockGi:
    """Mock for gi."""

    @staticmethod
    def require_version(name, version):
        """Mock require_version."""
        pass

    class repository:
        """Mock for gi.repository."""

        class GLib:
            """Mock for gi.repository.GLib."""

            class MainLoop:
                """Mock for GLib.MainLoop."""

                def __init__(self):
                    pass

                def run(self):
                    pass
